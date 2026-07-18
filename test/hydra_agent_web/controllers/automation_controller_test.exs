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

  test "automation creation routes reject agents from another workspace", %{conn: conn} do
    workspace = workspace_fixture(%{name: "Ops", slug: "ops-automation-api-scope"})

    other_workspace =
      workspace_fixture(%{name: "Other Ops", slug: "other-ops-automation-api-scope"})

    foreign_agent = agent_fixture(other_workspace, %{slug: "foreign-automation-api-agent"})

    conn =
      post(conn, ~p"/api/v1/workspaces/#{workspace.id}/automations", %{
        agent_id: foreign_agent.id,
        name: "Foreign agent automation",
        slug: "foreign-agent-automation",
        cron_expression: "0 9 * * *",
        prompt: "This must not be created."
      })

    assert %{"errors" => %{"agent_id" => ["must belong to the same workspace"]}} =
             json_response(conn, 422)

    conn =
      post(
        build_conn(),
        ~p"/api/v1/workspaces/#{workspace.id}/automation_recipes/daily_briefing",
        %{agent_id: foreign_agent.id}
      )

    assert %{"errors" => %{"agent_id" => ["must belong to the same workspace"]}} =
             json_response(conn, 422)

    assert Automations.list_automations(workspace.id) == []
    assert Automations.list_automations(other_workspace.id) == []
  end
end
