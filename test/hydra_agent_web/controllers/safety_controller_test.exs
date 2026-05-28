defmodule HydraAgentWeb.SafetyControllerTest do
  use HydraAgentWeb.ConnCase

  import HydraAgent.RuntimeFixtures

  alias HydraAgent.Safety

  test "filters safety events by run_id", %{conn: conn} do
    workspace = workspace_fixture(%{name: "Ops", slug: "ops-safety-api"})
    run = run_fixture(workspace, %{title: "Filtered", goal: "Show matching safety events"})
    other_run = run_fixture(workspace, %{title: "Other", goal: "Stay out of the response"})

    {:ok, _event} =
      Safety.record_event(%{
        workspace_id: workspace.id,
        run_id: run.id,
        category: "runtime",
        severity: "info",
        action: "matching_event",
        summary: "Included"
      })

    {:ok, _event} =
      Safety.record_event(%{
        workspace_id: workspace.id,
        run_id: other_run.id,
        category: "runtime",
        severity: "info",
        action: "other_event",
        summary: "Excluded"
      })

    conn = get(conn, ~p"/api/v1/workspaces/#{workspace.id}/safety/events?run_id=#{run.id}")

    assert %{"data" => [%{"action" => "matching_event", "run_id" => run_id}]} =
             json_response(conn, 200)

    assert run_id == run.id
  end
end
