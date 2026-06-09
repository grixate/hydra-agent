defmodule HydraAgentWeb.LoopControllerTest do
  use HydraAgentWeb.ConnCase

  import HydraAgent.RuntimeFixtures

  alias HydraAgent.Loops

  test "loop API exposes recipes", %{conn: conn} do
    workspace = workspace_fixture(%{slug: "loop-api-recipes"})

    conn = get(conn, ~p"/api/v1/workspaces/#{workspace.id}/loop_recipes")

    assert %{"data" => recipes} = json_response(conn, 200)
    assert Enum.any?(recipes, &(&1["id"] == "runtime_doctor_loop"))
  end

  test "loop API creates, updates, and controls loops", %{conn: conn} do
    workspace = workspace_fixture(%{slug: "loop-api-crud"})
    agent = agent_fixture(workspace, %{slug: "loop-api-agent", role: "supervisor"})

    conn =
      post(conn, ~p"/api/v1/workspaces/#{workspace.id}/loops", %{
        name: "API Loop",
        slug: "api-loop",
        status: "draft",
        purpose: "Exercise the loop API.",
        supervisor_agent_id: agent.id,
        trigger: %{"type" => "manual"}
      })

    assert %{"data" => %{"id" => id, "status" => "draft", "slug" => "api-loop"}} =
             json_response(conn, 201)

    conn =
      patch(conn, ~p"/api/v1/workspaces/#{workspace.id}/loops/#{id}", %{
        status: "active",
        trigger: %{
          "type" => "cron",
          "cron_expression" => "0 9 * * *",
          "timezone" => "Etc/UTC"
        }
      })

    assert %{"data" => %{"status" => "active", "next_tick_at" => next_tick_at}} =
             json_response(conn, 200)

    assert is_binary(next_tick_at)

    conn = post(conn, ~p"/api/v1/workspaces/#{workspace.id}/loops/#{id}/pause")
    assert %{"data" => %{"status" => "paused"}} = json_response(conn, 200)

    conn = post(conn, ~p"/api/v1/workspaces/#{workspace.id}/loops/#{id}/resume")
    assert %{"data" => %{"status" => "active"}} = json_response(conn, 200)

    conn = post(conn, ~p"/api/v1/workspaces/#{workspace.id}/loops/#{id}/archive")
    assert %{"data" => %{"status" => "archived"}} = json_response(conn, 200)
  end

  test "loop API can create from recipe", %{conn: conn} do
    workspace = workspace_fixture(%{slug: "loop-api-recipe-create"})
    agent = agent_fixture(workspace, %{slug: "loop-api-recipe-agent", role: "supervisor"})

    conn =
      post(conn, ~p"/api/v1/workspaces/#{workspace.id}/loop_recipes/runtime_doctor_loop", %{
        supervisor_agent_id: agent.id,
        status: "draft"
      })

    assert %{"data" => %{"slug" => "runtime-doctor-loop", "status" => "draft"}} =
             json_response(conn, 201)
  end

  test "loop API trigger reports provider decision failures", %{conn: conn} do
    workspace = workspace_fixture(%{slug: "loop-api-trigger"})
    agent = agent_fixture(workspace, %{slug: "loop-api-trigger-agent", role: "supervisor"})
    loop = loop_fixture(workspace, %{supervisor_agent: agent})

    conn = post(conn, ~p"/api/v1/workspaces/#{workspace.id}/loops/#{loop.id}/trigger")

    assert %{"errors" => %{"reason" => reason}} = json_response(conn, 422)
    assert is_binary(reason)

    assert Loops.get_loop!(loop.id).status == "blocked"
  end
end
