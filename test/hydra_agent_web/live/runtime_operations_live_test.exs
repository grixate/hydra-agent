defmodule HydraAgentWeb.RuntimeOperationsLiveTest do
  use HydraAgentWeb.ConnCase

  import HydraAgent.RuntimeFixtures
  import Phoenix.LiveViewTest

  alias HydraAgent.Runtime
  alias HydraAgent.Safety

  test "renders empty runtime operations page", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/control/runtime")

    assert html =~ "Runtime Operations"
    assert html =~ "No workspaces yet."
  end

  test "falls back from malformed workspace params", %{conn: conn} do
    workspace = workspace_fixture(%{name: "Ops", slug: "ops-runtime-malformed-param"})

    {:ok, view, html} = live(conn, ~p"/control/runtime?workspace_id=not-an-id")

    assert html =~ "Runtime Operations"
    assert render(view) =~ workspace.name
  end

  test "renders queue pressure, stale leases, providers, incidents, and topology", %{conn: conn} do
    workspace = workspace_fixture(%{name: "Ops", slug: "ops-runtime"})
    agent = agent_fixture(workspace)

    {:ok, planned_run} =
      Runtime.create_run(%{
        workspace_id: workspace.id,
        supervisor_agent_id: agent.id,
        title: "Planned mission",
        goal: "Wait in queue",
        status: "planned"
      })

    {:ok, running_run} =
      Runtime.create_run(%{
        workspace_id: workspace.id,
        supervisor_agent_id: agent.id,
        title: "Running mission",
        goal: "Has stale work",
        status: "running"
      })

    expired_at =
      DateTime.utc_now() |> DateTime.add(-60, :second) |> DateTime.truncate(:microsecond)

    {:ok, stale_step} =
      Runtime.create_run_step(running_run, %{
        assigned_agent_id: agent.id,
        index: 0,
        title: "Expired lease step",
        status: "running",
        tool_name: "noop",
        side_effect_class: "read_only",
        lease_owner: "stale-worker",
        lease_expires_at: expired_at,
        attempt_count: 2
      })

    {:ok, awaiting_step} =
      Runtime.create_run_step(planned_run, %{
        assigned_agent_id: agent.id,
        index: 1,
        title: "Needs approval",
        status: "awaiting_approval",
        tool_name: "knowledge_write",
        side_effect_class: "workspace_write"
      })

    {:ok, provider} =
      Runtime.create_provider(%{
        workspace_id: workspace.id,
        name: "Mock Provider",
        kind: "mock",
        model: "mock-1",
        metadata: %{"fallback_providers" => ["Backup Provider"]}
      })

    {:ok, incident} =
      Safety.record_event(%{
        workspace_id: workspace.id,
        category: "runtime",
        severity: "warning",
        action: "lease_recovery",
        summary: "Recovered expired worker lease"
      })

    {:ok, view, _html} = live(conn, ~p"/control/runtime?workspace_id=#{workspace.id}")

    assert has_element?(view, "#runtime-operations")
    assert has_element?(view, "#runtime-worker-#{planned_run.id}")
    assert has_element?(view, "#runtime-worker-#{running_run.id}")
    assert has_element?(view, "#runtime-stale-step-#{stale_step.id}")
    assert has_element?(view, "#runtime-awaiting-step-#{awaiting_step.id}")
    assert has_element?(view, "#runtime-provider-#{provider.id}")
    assert has_element?(view, "#runtime-incident-#{incident.id}")
    assert has_element?(view, "#runtime-topology")

    html = render(view)
    assert html =~ "Expired lease step"
    assert html =~ "Needs approval"
    assert html =~ "Mock Provider"
    assert html =~ "route Mock Provider -&gt; Backup Provider"
    assert html =~ "Recovered expired worker lease"
    assert html =~ "HydraAgent.Runtime.RecoveryWorker"
  end
end
