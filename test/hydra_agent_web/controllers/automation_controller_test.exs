defmodule HydraAgentWeb.AutomationControllerTest do
  use HydraAgentWeb.ConnCase

  import HydraAgent.RuntimeFixtures

  alias HydraAgent.Automations

  test "automation API exposes connector readiness", %{conn: conn} do
    workspace = workspace_fixture(%{name: "Ops", slug: "ops-automation-api-readiness"})
    agent = agent_fixture(workspace, %{slug: "automation-api-agent"})

    {:ok, automation} =
      Automations.create_automation(%{
        workspace_id: workspace.id,
        agent_id: agent.id,
        name: "API Readiness",
        slug: "api-readiness",
        cron_expression: "0 9 * * *",
        prompt: "Run.",
        metadata: %{"required_connectors" => ["email"]}
      })

    conn = get(conn, ~p"/api/v1/workspaces/#{workspace.id}/automations")
    automation_id = automation.id

    assert %{
             "data" => [
               %{
                 "id" => ^automation_id,
                 "readiness" => %{
                   "status" => "blocked",
                   "required_connectors" => ["email"],
                   "blockers" => [%{"provider" => "email", "reason" => "connector_missing"}]
                 }
               }
             ]
           } = json_response(conn, 200)
  end
end
