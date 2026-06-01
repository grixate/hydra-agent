defmodule HydraAgentWeb.AgentControllerTest do
  use HydraAgentWeb.ConnCase

  import HydraAgent.RuntimeFixtures

  alias HydraAgent.Runtime

  test "serves the agent pack JSON schema", %{conn: conn} do
    conn = get(conn, ~p"/api/v1/agents/pack_schema")

    assert %{
             "data" => %{
               "$id" => id,
               "properties" => %{
                 "agent_pack_version" => %{"const" => 1},
                 "tools" => %{"items" => %{"enum" => tools}},
                 "tool_bundles" => %{"items" => %{"enum" => bundles}}
               }
             }
           } = json_response(conn, 200)

    assert id =~ "agent-pack-v1"
    assert "knowledge_search" in tools
    assert "files_read" in bundles
  end

  test "serves bundled starter packs with productization metadata", %{conn: conn} do
    conn = get(conn, ~p"/api/v1/agents/starter_packs")

    assert %{"data" => packs} = json_response(conn, 200)
    daily = Enum.find(packs, &(get_in(&1, ["pack", "slug"]) == "daily-chief-of-staff"))

    assert daily["status"] == "valid"
    assert get_in(daily, ["pack", "task_pack"]) == "daily_os"
    assert "telegram" in get_in(daily, ["pack", "connector_requirements"])
    assert "daily_briefing" in get_in(daily, ["pack", "automation_recipes"])
  end

  test "import pack failures include stable structured details", %{conn: conn} do
    workspace = workspace_fixture(%{name: "Ops", slug: "ops-agent-pack-details"})

    conn =
      post(conn, ~p"/api/v1/workspaces/#{workspace.id}/agents/import_pack", %{
        agent_pack: %{
          agent_pack_version: 99,
          slug: "bad-agent",
          name: "Bad Agent",
          role: "wizard",
          description: "Invalid pack.",
          model_route: %{},
          tools: ["made_up_tool"],
          tool_bundles: ["imaginary"],
          skills: [],
          memory_scopes: ["agent"],
          knowledge_scopes: ["workspace"],
          permissions: %{side_effect_classes: ["telepathy"], requires_approval: true},
          autonomy: %{level: "too_much"},
          approval_policy: %{mode: "whenever"}
        }
      })

    assert %{"errors" => errors, "details" => details} = json_response(conn, 422)

    assert "agent_pack_version must be 1" in errors
    assert Enum.any?(details, &(&1["code"] == "unsupported_version"))

    assert %{
             "field" => "tools",
             "code" => "unknown_registered_tools",
             "metadata" => %{"unknown" => ["made_up_tool"]}
           } = Enum.find(details, &(&1["field"] == "tools"))
  end

  test "dry-run import validates without creating an agent", %{conn: conn} do
    workspace = workspace_fixture(%{name: "Ops", slug: "ops-agent-pack-dry-run"})

    conn =
      post(conn, ~p"/api/v1/workspaces/#{workspace.id}/agents/import_pack", %{
        mode: "dry_run",
        agent_pack: valid_pack("runtime-reviewer")
      })

    assert %{
             "data" => %{
               "mode" => "dry_run",
               "existing_agent_id" => nil,
               "agent_attrs" => %{
                 "slug" => "runtime-reviewer",
                 "capability_profile" => %{"skills" => ["runtime_review"]}
               }
             }
           } = json_response(conn, 200)

    assert Runtime.list_agents(workspace.id) == []
  end

  test "update_existing import replaces the matching agent profile", %{conn: conn} do
    workspace = workspace_fixture(%{name: "Ops", slug: "ops-agent-pack-update"})
    agent = agent_fixture(workspace, %{slug: "runtime-reviewer", description: "Old description"})

    conn =
      post(conn, ~p"/api/v1/workspaces/#{workspace.id}/agents/import_pack", %{
        mode: "update_existing",
        agent_pack: valid_pack("runtime-reviewer", %{"description" => "Updated from pack"})
      })

    assert %{"data" => %{"id" => id, "description" => "Updated from pack"}} =
             json_response(conn, 200)

    assert id == agent.id
    assert Runtime.get_agent!(agent.id).description == "Updated from pack"
  end

  test "clone import creates a collision-free copy", %{conn: conn} do
    workspace = workspace_fixture(%{name: "Ops", slug: "ops-agent-pack-clone"})
    _agent = agent_fixture(workspace, %{slug: "runtime-reviewer", name: "Runtime Reviewer"})

    conn =
      post(conn, ~p"/api/v1/workspaces/#{workspace.id}/agents/import_pack", %{
        mode: "clone",
        agent_pack: valid_pack("runtime-reviewer")
      })

    assert %{"data" => %{"slug" => "runtime-reviewer-copy-1", "name" => "Runtime Reviewer Copy"}} =
             json_response(conn, 201)
  end

  test "import rejects unsupported modes", %{conn: conn} do
    workspace = workspace_fixture(%{name: "Ops", slug: "ops-agent-pack-mode"})

    conn =
      post(conn, ~p"/api/v1/workspaces/#{workspace.id}/agents/import_pack", %{
        mode: "teleport",
        agent_pack: valid_pack("runtime-reviewer")
      })

    assert %{"errors" => %{"mode" => ["must be one of create, dry_run, update_existing, clone"]}} =
             json_response(conn, 422)
  end

  defp valid_pack(slug, overrides \\ %{}) do
    %{
      "agent_pack_version" => 1,
      "slug" => slug,
      "name" => "Runtime Reviewer",
      "role" => "reviewer",
      "description" => "Reviews runtime state.",
      "model_route" => %{"default_provider" => "mock"},
      "tools" => ["knowledge_search"],
      "skills" => ["runtime_review"],
      "memory_scopes" => ["agent"],
      "knowledge_scopes" => ["workspace"],
      "permissions" => %{"side_effect_classes" => ["read_only"], "requires_approval" => true},
      "autonomy" => %{"level" => "recommend"},
      "approval_policy" => %{"mode" => "required_for_sensitive"}
    }
    |> Map.merge(overrides)
  end
end
