defmodule HydraAgentWeb.AgentDirectoryLiveTest do
  use HydraAgentWeb.ConnCase

  import HydraAgent.RuntimeFixtures
  import Phoenix.LiveViewTest

  alias HydraAgent.Runtime
  alias HydraAgent.Skills

  test "renders empty agent directory", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/control/agents")

    assert html =~ "Agent Directory"
    assert html =~ "No workspaces yet."
  end

  test "falls back from malformed workspace params", %{conn: conn} do
    workspace = workspace_fixture(%{name: "Ops", slug: "ops-agent-directory-malformed-param"})

    {:ok, view, html} = live(conn, ~p"/control/agents?workspace_id=not-an-id")

    assert html =~ "Agent Directory"
    assert render(view) =~ workspace.name
  end

  test "renders agent directory from real workspace state", %{conn: conn} do
    workspace = workspace_fixture(%{name: "Ops", slug: "ops-agent-directory"})

    agent =
      agent_fixture(workspace, %{
        name: "Runtime Steward",
        slug: "runtime-steward",
        role: "operator",
        description: "Keeps runtime missions moving.",
        model_route: %{"provider" => "openai", "model" => "gpt-5"},
        capability_profile: %{
          "tools" => ["noop", "knowledge_read"],
          "skills" => ["runtime_triage"],
          "side_effect_classes" => ["read_only"],
          "max_autonomy_level" => "execute_with_review",
          "approval_policy" => %{"mode" => "required_for_sensitive"}
        },
        memory_scopes: ["workspace"],
        knowledge_scopes: ["workspace"]
      })

    {:ok, _policy} =
      Runtime.create_tool_policy(%{
        workspace_id: workspace.id,
        agent_id: agent.id,
        allowed_tools: ["noop"],
        side_effect_classes: ["read_only"],
        requires_approval: false
      })

    {:ok, _skill} =
      Skills.create_skill(%{
        workspace_id: workspace.id,
        owner_agent_id: agent.id,
        name: "Runtime Triage",
        slug: "runtime-triage",
        description: "Inspect stuck runs.",
        instructions: "Look for blocked work.",
        required_tools: ["knowledge_read"]
      })

    {:ok, _run} =
      Runtime.create_run(%{
        workspace_id: workspace.id,
        supervisor_agent_id: agent.id,
        title: "Inspect worker health",
        goal: "Find stalled missions",
        status: "running"
      })

    {:ok, view, _html} = live(conn, ~p"/control/agents?workspace_id=#{workspace.id}")

    assert has_element?(view, "#agent-directory")
    assert has_element?(view, "#agent-card-#{agent.id}")

    html = render(view)
    assert html =~ "Runtime Steward"
    assert html =~ "openai / gpt-5"
    assert html =~ "execute_with_review / required_for_sensitive"
    assert html =~ "1 declared / 1 durable"
    assert html =~ "policies 1 / runs 1"
    assert html =~ "running 1"
  end

  test "renders agent detail with runs, steps, skills, scopes, and policies", %{conn: conn} do
    workspace = workspace_fixture(%{name: "Ops", slug: "ops-agent-detail"})

    agent =
      agent_fixture(workspace, %{
        name: "Memory Curator",
        slug: "memory-curator",
        role: "operator",
        description: "Reviews memory and graph changes.",
        model_route: %{"provider" => "anthropic", "model" => "claude-sonnet"},
        capability_profile: %{
          "tools" => ["knowledge_read", "knowledge_write"],
          "tool_bundles" => ["knowledge"],
          "skills" => ["memory_review"],
          "side_effect_classes" => ["read_only", "workspace_write"],
          "max_autonomy_level" => "execute_with_approval",
          "approval_policy" => %{"mode" => "always"}
        },
        memory_scopes: ["workspace", "agent"],
        knowledge_scopes: ["workspace"]
      })

    {:ok, policy} =
      Runtime.create_tool_policy(%{
        workspace_id: workspace.id,
        agent_id: agent.id,
        allowed_tools: ["knowledge_read", "knowledge_write"],
        side_effect_classes: ["read_only", "workspace_write"],
        shell_env_allowlist: ["HYDRA_ALLOWED_FLAG"],
        requires_approval: true
      })

    {:ok, skill} =
      Skills.create_skill(%{
        workspace_id: workspace.id,
        owner_agent_id: agent.id,
        name: "Memory Review",
        slug: "memory-review",
        status: "active",
        description: "Review durable memory proposals.",
        instructions: "Check provenance before promoting.",
        required_tools: ["knowledge_read"]
      })

    {:ok, run} =
      Runtime.create_run(%{
        workspace_id: workspace.id,
        supervisor_agent_id: agent.id,
        title: "Review proposals",
        goal: "Promote high-signal memory"
      })

    {:ok, step} =
      Runtime.create_run_step(run, %{
        assigned_agent_id: agent.id,
        index: 0,
        title: "Read candidate memory",
        tool_name: "knowledge_read",
        side_effect_class: "read_only"
      })

    {:ok, view, _html} = live(conn, ~p"/control/agents/#{agent.id}?workspace_id=#{workspace.id}")

    assert has_element?(view, "#agent-detail")
    assert has_element?(view, "#agent-detail-run-#{run.id}")
    assert has_element?(view, "#agent-detail-step-#{step.id}")
    assert has_element?(view, "#agent-detail-skill-#{skill.id}")
    assert has_element?(view, "#agent-detail-policy-#{policy.id}")

    html = render(view)
    assert html =~ "Memory Curator"
    assert html =~ "claude-sonnet"
    assert html =~ "execute_with_approval"
    assert html =~ "knowledge_read, knowledge_write"
    assert html =~ "memory workspace, agent"
    assert html =~ "Review proposals"
    assert html =~ "Read candidate memory"
    assert html =~ "Memory Review"
    assert html =~ "shell env HYDRA_ALLOWED_FLAG"
  end
end
