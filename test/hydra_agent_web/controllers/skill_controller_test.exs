defmodule HydraAgentWeb.SkillControllerTest do
  use HydraAgentWeb.ConnCase

  import HydraAgent.RuntimeFixtures

  alias HydraAgent.{Runtime, Skills}

  test "skill learning APIs expose proposals, usage, and markdown export", %{conn: conn} do
    workspace = workspace_fixture(%{slug: "skill-controller-learning"})
    agent = agent_fixture(workspace, %{slug: "skill-controller-agent"})

    run =
      run_fixture(workspace, %{
        supervisor_agent_id: agent.id,
        title: "Controller Learning",
        goal: "Use repeated knowledge reads."
      })

    for index <- 0..4 do
      run_step_fixture(run, %{
        index: index,
        title: "Read #{index}",
        tool_name: "knowledge_read",
        side_effect_class: "read_only"
      })
    end

    {:ok, completed} = Runtime.complete_run(run)

    conn =
      post(
        conn,
        ~p"/api/v1/workspaces/#{workspace.id}/skills/propose_from_run/#{completed.id}",
        %{}
      )

    assert %{
             "data" => %{
               "id" => proposal_id,
               "status" => "auto_activated",
               "target_skill_id" => skill_id
             }
           } =
             json_response(conn, 201)

    conn =
      get(build_conn(), ~p"/api/v1/workspaces/#{workspace.id}/skills/improvement_proposals")

    assert %{"data" => [_proposal]} = json_response(conn, 200)

    conn = get(build_conn(), ~p"/api/v1/workspaces/#{workspace.id}/skills/usage")
    assert %{"data" => [%{"skill_id" => ^skill_id, "tool_count" => 5}]} = json_response(conn, 200)

    conn = get(build_conn(), ~p"/api/v1/skills/#{skill_id}/export_markdown")
    assert response(conn, 200) =~ "Controller Learning"

    proposal = Skills.get_improvement_proposal!(proposal_id)
    assert proposal.status == "auto_activated"
  end

  test "imports markdown skills through workspace API", %{conn: conn} do
    workspace = workspace_fixture(%{slug: "skill-controller-import"})

    markdown = """
    ---
    {"name":"Imported Controller Skill","slug":"imported-controller-skill","required_tools":["knowledge_read"]}
    ---
    # Imported Controller Skill

    Follow the imported procedure.
    """

    conn =
      post(conn, ~p"/api/v1/workspaces/#{workspace.id}/skills/import_markdown", %{
        markdown: markdown,
        description: "Imported via API"
      })

    assert %{
             "data" => %{
               "slug" => "imported-controller-skill",
               "required_tools" => ["knowledge_read"]
             }
           } =
             json_response(conn, 201)
  end

  test "skill ecosystem APIs seed packs, generate evals, and manage proposals", %{conn: conn} do
    workspace = workspace_fixture(%{slug: "skill-controller-ecosystem"})

    conn = post(conn, ~p"/api/v1/workspaces/#{workspace.id}/skills/seed_pack", %{})

    assert %{"data" => seeded} = json_response(conn, 201)
    assert length(seeded) == 5

    skill_id =
      seeded
      |> Enum.find(&(&1["slug"] == "run-failure-triage"))
      |> Map.fetch!("id")

    conn = post(build_conn(), ~p"/api/v1/skills/#{skill_id}/eval_suite", %{})

    assert %{"data" => %{"skill" => skill_payload, "suite" => suite_payload}} =
             json_response(conn, 201)

    suite_slug = skill_payload["evals"]["suite_id"]
    assert suite_payload["slug"] == suite_slug
    cases = suite_payload["cases"]
    assert length(cases) == 3

    conn =
      post(build_conn(), ~p"/api/v1/skills/#{skill_id}/improvement_proposals/refine", %{
        description: "Refined by controller",
        instructions: "Refined instructions"
      })

    assert %{"data" => %{"kind" => "refine", "status" => "draft", "id" => refine_id}} =
             json_response(conn, 201)

    conn = post(build_conn(), ~p"/api/v1/skill_improvement_proposals/#{refine_id}/approve", %{})

    assert %{"data" => %{"skill" => %{"description" => "Refined by controller"}}} =
             json_response(conn, 200)

    conn =
      post(build_conn(), ~p"/api/v1/skills/#{skill_id}/improvement_proposals/prune", %{
        metadata: %{reason: "superseded"}
      })

    assert %{"data" => %{"kind" => "prune", "status" => "draft", "id" => prune_id}} =
             json_response(conn, 201)

    conn = post(build_conn(), ~p"/api/v1/skill_improvement_proposals/#{prune_id}/reject", %{})
    assert %{"data" => %{"status" => "rejected"}} = json_response(conn, 200)

    conn =
      post(build_conn(), ~p"/api/v1/skills/#{skill_id}/restore_version", %{
        version: 1,
        actor: "controller-test"
      })

    assert %{
             "data" => %{
               "id" => ^skill_id,
               "provenance" => %{"restored_from_version" => 1}
             }
           } = json_response(conn, 200)
  end

  test "conversation, code skill, directory import, and experiment APIs", %{conn: conn} do
    root =
      Path.join(
        System.tmp_dir!(),
        "hydra-controller-code-skill-#{System.unique_integer([:positive])}"
      )

    workspace =
      workspace_fixture(%{
        slug: "skill-controller-v5",
        settings: %{"project_root" => root}
      })

    agent = agent_fixture(workspace, %{slug: "skill-controller-v5-agent"})

    {:ok, conversation} =
      Runtime.create_conversation(%{
        workspace_id: workspace.id,
        agent_id: agent.id,
        title: "Controller Conversation Learning",
        channel: "api"
      })

    {:ok, _turn} =
      Runtime.append_turn(conversation, %{role: "user", content: "Summarize evidence"})

    {:ok, _turn} =
      Runtime.append_turn(conversation, %{role: "assistant", content: "I will read context"})

    {:ok, _turn} =
      Runtime.append_turn(conversation, %{
        role: "tool",
        kind: "tool_call",
        content: "read",
        metadata: %{"tool_name" => "knowledge_read"}
      })

    {:ok, _turn} =
      Runtime.append_turn(conversation, %{role: "assistant", content: "Evidence summary"})

    conn =
      post(
        conn,
        ~p"/api/v1/workspaces/#{workspace.id}/skills/propose_from_conversation/#{conversation.id}",
        %{confidence: 0.9}
      )

    assert %{
             "data" => %{
               "source_conversation_id" => conversation_id,
               "target_skill_id" => skill_id
             }
           } =
             json_response(conn, 201)

    assert conversation_id == conversation.id

    conn =
      post(build_conn(), ~p"/api/v1/workspaces/#{workspace.id}/skills/code_skill", %{
        name: "Controller Code Skill",
        slug: "controller-code-skill",
        description: "Run controller code helper.",
        files: %{"scripts/run.sh" => "echo ok\n"}
      })

    assert %{"data" => %{"slug" => "controller-code-skill", "provenance" => provenance}} =
             json_response(conn, 201)

    assert provenance["kind"] == "project_code_skill"

    assert File.regular?(
             Path.join([root, ".hydra", "skills", "controller-code-skill", "scripts/run.sh"])
           )

    import_dir = Path.join(root, "hermes-import")
    File.mkdir_p!(import_dir)

    File.write!(Path.join(import_dir, "SKILL.md"), """
    ---
    name: imported-hermes-api
    description: Imported through API.
    required_tools: [knowledge_read]
    ---

    # Imported Hermes API

    Follow the borrowed skill.
    """)

    conn =
      post(build_conn(), ~p"/api/v1/workspaces/#{workspace.id}/skills/import_directory", %{
        path: import_dir
      })

    assert %{"data" => %{"slug" => "imported-hermes-api"}} = json_response(conn, 201)

    conn =
      post(build_conn(), ~p"/api/v1/skills/#{skill_id}/experiments", %{
        examples: [%{prompt: "Summarize and verify", expected: %{contains: ["verify"]}}],
        variants: [%{candidate: "verify_variant", instructions: "Summarize and verify claims."}]
      })

    assert %{
             "data" => %{
               "status" => "completed",
               "selected_proposal_id" => selected_proposal_id,
               "winner_snapshot" => %{"experiment_candidate" => "verify_variant"}
             }
           } = json_response(conn, 201)

    assert selected_proposal_id

    conn = get(build_conn(), ~p"/api/v1/workspaces/#{workspace.id}/skills/experiments")
    assert %{"data" => [%{"id" => _id} | _rest]} = json_response(conn, 200)
  end

  test "workspace API runs safe skill evolution due pass", %{conn: conn} do
    workspace = workspace_fixture(%{slug: "skill-controller-evolve-due"})
    agent = agent_fixture(workspace, %{slug: "skill-controller-evolve-agent"})

    {:ok, conversation} =
      Runtime.create_conversation(%{
        workspace_id: workspace.id,
        agent_id: agent.id,
        title: "Controller auto evolution",
        channel: "telegram"
      })

    for {role, content, metadata} <- [
          {"user", "Summarize source evidence", %{}},
          {"assistant", "I will read approved notes", %{}},
          {"tool", "read notes", %{"tool_name" => "knowledge_read"}},
          {"assistant", "Evidence summary with citations", %{}},
          {"user", "Make this reusable", %{}},
          {"assistant", "Reusable evidence workflow captured", %{}}
        ] do
      {:ok, _turn} =
        Runtime.append_turn(conversation, %{
          role: role,
          content: content,
          metadata: metadata
        })
    end

    conn =
      post(conn, ~p"/api/v1/workspaces/#{workspace.id}/skills/evolve_due", %{
        minimum_turn_count: 4
      })

    assert %{
             "data" => %{
               "auto_activated" => 1,
               "drafted" => 0,
               "results" => [%{"policy_decision" => "auto_activated"}]
             }
           } = json_response(conn, 201)
  end
end
