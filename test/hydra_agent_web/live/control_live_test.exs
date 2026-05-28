defmodule HydraAgentWeb.ControlLiveTest do
  use HydraAgentWeb.ConnCase

  import HydraAgent.RuntimeFixtures
  import Phoenix.LiveViewTest

  alias HydraAgent.Knowledge
  alias HydraAgent.MCP
  alias HydraAgent.Memory
  alias HydraAgent.Runtime

  test "renders empty control plane", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/control")

    assert html =~ "Runtime Console"
    assert html =~ "No workspaces yet."
  end

  test "falls back from malformed workspace params", %{conn: conn} do
    workspace = workspace_fixture(%{name: "Ops", slug: "ops-control-malformed-param"})

    {:ok, view, html} = live(conn, ~p"/control?workspace_id=not-an-id")

    assert html =~ "Runtime Console"
    assert render(view) =~ workspace.name
  end

  test "renders workspace runtime panels", %{conn: conn} do
    {:ok, workspace} = Runtime.create_workspace(%{name: "Ops", slug: "ops"})

    {:ok, _run} =
      Runtime.create_run(%{
        workspace_id: workspace.id,
        title: "Check runtime",
        goal: "Inspect current state"
      })

    {:ok, view, _html} = live(conn, ~p"/control")

    assert has_element?(view, "#control-plane")
    assert has_element?(view, "#control-shell-nav")
    assert has_element?(view, "#control-runs")
    assert has_element?(view, "#control-graph")
    html = render(view)
    assert html =~ "Check runtime"
    assert html =~ "Agents"
    assert html =~ "Memory"
    assert html =~ "Graph"
    assert html =~ "Skills"
    assert html =~ "Automations"
    assert html =~ "Runtime"
    assert html =~ "Tools"
  end

  test "run action buttons update durable run state", %{conn: conn} do
    {:ok, workspace} = Runtime.create_workspace(%{name: "Ops", slug: "ops-actions"})

    {:ok, run} =
      Runtime.create_run(%{
        workspace_id: workspace.id,
        title: "Control action",
        goal: "Exercise run controls"
      })

    {:ok, view, _html} = live(conn, ~p"/control?workspace_id=#{workspace.id}")

    view |> element("#control-start-run-#{run.id}") |> render_click()
    assert Runtime.get_run!(run.id).status == "running"

    view |> element("#control-pause-run-#{run.id}") |> render_click()
    assert Runtime.get_run!(run.id).status == "paused"

    view |> element("#control-resume-run-#{run.id}") |> render_click()
    assert Runtime.get_run!(run.id).status == "running"

    view |> element("#control-cancel-run-#{run.id}") |> render_click()
    assert Runtime.get_run!(run.id).status == "canceled"
  end

  test "approval buttons update awaiting steps", %{conn: conn} do
    {:ok, workspace} = Runtime.create_workspace(%{name: "Ops", slug: "ops-approvals"})

    {:ok, run} =
      Runtime.create_run(%{
        workspace_id: workspace.id,
        title: "Approval run",
        goal: "Exercise approvals"
      })

    {:ok, approve_step} =
      Runtime.create_run_step(run, %{
        index: 0,
        title: "Approve me",
        status: "awaiting_approval",
        tool_name: "knowledge_write",
        side_effect_class: "workspace_write"
      })

    {:ok, reject_step} =
      Runtime.create_run_step(run, %{
        index: 1,
        title: "Reject me",
        status: "awaiting_approval",
        tool_name: "knowledge_write",
        side_effect_class: "workspace_write"
      })

    {:ok, view, _html} = live(conn, ~p"/control?workspace_id=#{workspace.id}")

    view |> element("#control-approve-step-#{approve_step.id}") |> render_click()
    assert Runtime.get_run_step!(approve_step.id).status == "planned"

    view |> element("#control-reject-step-#{reject_step.id}") |> render_click()
    assert Runtime.get_run_step!(reject_step.id).status == "canceled"
  end

  test "memory review buttons promote and reject pending proposals", %{conn: conn} do
    workspace = workspace_fixture(%{name: "Ops", slug: "ops-memory-live"})
    agent = agent_fixture(workspace, %{knowledge_scopes: ["workspace"]})

    {:ok, promote_me} =
      Memory.propose_node(agent, %{
        title: "Remember durable events",
        body: "Use run events as the source of truth for mission timelines."
      })

    {:ok, reject_me} =
      Memory.propose_node(agent, %{
        title: "Loose thought",
        body: "This one is not specific enough for recall."
      })

    {:ok, view, _html} = live(conn, ~p"/control?workspace_id=#{workspace.id}")

    assert has_element?(view, "#control-memory-proposals")
    assert render(view) =~ "Remember durable events"
    assert render(view) =~ "Loose thought"

    view
    |> element("#control-review-memory-form-#{promote_me.id}")
    |> render_submit(%{
      proposal_id: promote_me.id,
      decision: "promote",
      reason: "Verified from mission timeline"
    })

    promoted = HydraAgent.Knowledge.get_node!(promote_me.id)
    assert promoted.status == "active"
    assert promoted.attributes["proposal_status"] == "promoted"
    assert promoted.attributes["review_reason"] == "Verified from mission timeline"

    view
    |> element("#control-review-memory-form-#{reject_me.id}")
    |> render_submit(%{
      proposal_id: reject_me.id,
      decision: "reject",
      reason: "Too vague for recall"
    })

    rejected = HydraAgent.Knowledge.get_node!(reject_me.id)
    assert rejected.status == "archived"
    assert rejected.attributes["proposal_status"] == "rejected"
    assert rejected.attributes["review_reason"] == "Too vague for recall"

    refute has_element?(view, "#control-memory-proposal-#{promote_me.id}")
    refute has_element?(view, "#control-memory-proposal-#{reject_me.id}")
    assert render(view) =~ "No pending memory proposals."
  end

  test "renders graph provenance and recent relationships", %{conn: conn} do
    workspace = workspace_fixture(%{name: "Ops", slug: "ops-graph-live"})

    {:ok, decision} =
      Knowledge.create_node(%{
        workspace_id: workspace.id,
        type_key: "decision",
        title: "Use durable timelines",
        body: "Run detail reads persisted events.",
        provenance: %{"kind" => "operator_review"}
      })

    {:ok, artifact} =
      Knowledge.create_node(%{
        workspace_id: workspace.id,
        type_key: "memory",
        title: "Timeline memory",
        body: "Event streams are the source of truth.",
        provenance: %{"kind" => "memory_proposal"}
      })

    {:ok, relationship} =
      Knowledge.create_relationship(%{
        workspace_id: workspace.id,
        from_node_id: decision.id,
        to_node_id: artifact.id,
        type_key: "relates_to",
        confidence: 0.8,
        provenance: %{"kind" => "operator_link"}
      })

    {:ok, view, _html} = live(conn, ~p"/control?workspace_id=#{workspace.id}")

    assert has_element?(view, "#control-graph-provenance")
    assert has_element?(view, "#control-relationship-#{relationship.id}")
    html = render(view)
    assert html =~ "Use durable timelines relates_to Timeline memory"
    assert html =~ "provenance operator_link"
    assert html =~ "provenance operator_review"
  end

  test "renders tool bundles and policy bundle grants", %{conn: conn} do
    workspace = workspace_fixture(%{name: "Ops", slug: "ops-tool-bundles-live"})

    {:ok, policy} =
      Runtime.create_tool_policy(%{
        workspace_id: workspace.id,
        tool_bundles: ["files_read"],
        requires_approval: false,
        filesystem_allowlist: ["lib"]
      })

    {:ok, view, _html} = live(conn, ~p"/control?workspace_id=#{workspace.id}")

    assert has_element?(view, "#control-tool-bundles")
    assert has_element?(view, "#control-tool-bundle-files_read")
    assert has_element?(view, "#control-tool-policy-#{policy.id}")

    html = render(view)
    assert html =~ "files_read"
    assert html =~ "bundles files_read"
    assert html =~ "classes read_only"
  end

  test "renders MCP server protocol health and env refs", %{conn: conn} do
    workspace = workspace_fixture(%{name: "Ops", slug: "ops-mcp-live"})

    {:ok, server} =
      MCP.create_server(%{
        workspace_id: workspace.id,
        name: "Docs MCP",
        slug: "docs-mcp-live",
        transport: "http",
        config: %{"url" => "https://mcp.example.com"},
        env_refs: ["MCP_DOCS_TOKEN"],
        include_tools: ["search_docs"]
      })

    {:ok, view, _html} = live(conn, ~p"/control?workspace_id=#{workspace.id}")

    assert has_element?(view, "#control-mcp-servers")
    assert has_element?(view, "#control-mcp-server-#{server.id}")

    html = render(view)
    assert html =~ "Docs MCP"
    assert html =~ "http / sandboxed / unknown"
    assert html =~ "tools search_docs / env MCP_DOCS_TOKEN"
  end
end
