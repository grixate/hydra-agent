defmodule HydraAgentWeb.MissionControllerTest do
  use HydraAgentWeb.ConnCase

  import HydraAgent.RuntimeFixtures

  alias HydraAgent.Runtime

  test "creates, lists, shows, updates, and starts missions", %{conn: conn} do
    workspace = workspace_fixture(%{name: "Ops", slug: "ops-mission-api"})

    conn =
      post(conn, ~p"/api/v1/workspaces/#{workspace.id}/missions", %{
        title: "Research Hermes gaps",
        objective: "Map missing structure from Hermes agent",
        mission_type: "research",
        priority: 40
      })

    assert %{"data" => %{"id" => mission_id, "slug" => "research-hermes-gaps"}} =
             json_response(conn, 201)

    conn = get(build_conn(), ~p"/api/v1/workspaces/#{workspace.id}/missions?q=Hermes")
    assert %{"data" => [%{"id" => ^mission_id}]} = json_response(conn, 200)

    conn = patch(build_conn(), ~p"/api/v1/missions/#{mission_id}", %{status: "planned"})
    assert %{"data" => %{"status" => "planned"}} = json_response(conn, 200)

    conn = post(build_conn(), ~p"/api/v1/missions/#{mission_id}/start")

    assert %{
             "data" => %{
               "mission" => %{"status" => "running"},
               "run" => %{"mission_id" => ^mission_id, "status" => "running"}
             }
           } = json_response(conn, 200)
  end

  test "workspace-scoped mission routes reject foreign mission ids", %{conn: conn} do
    workspace = workspace_fixture(%{name: "Ops", slug: "ops-mission-scope"})
    other_workspace = workspace_fixture(%{name: "Other Ops", slug: "other-ops-mission-scope"})

    {:ok, mission} =
      Runtime.create_mission(%{
        workspace_id: workspace.id,
        title: "Scoped mission",
        objective: "Stay inside the workspace"
      })

    assert_error_sent 404, fn ->
      get(conn, ~p"/api/v1/workspaces/#{other_workspace.id}/missions/#{mission.id}")
    end
  end

  test "run trace and lineage endpoints expose mission context", %{conn: conn} do
    workspace = workspace_fixture(%{name: "Ops", slug: "ops-run-lineage-api"})

    {:ok, run} =
      Runtime.create_run(%{
        workspace_id: workspace.id,
        title: "Implement trace",
        goal: "Export observability data"
      })

    conn = post(conn, ~p"/api/v1/runs/#{run.id}/retry", %{lineage_reason: "bug hunt"})

    assert %{"data" => %{"parent_run_id" => parent_run_id, "lineage_type" => "retry"}} =
             json_response(conn, 200)

    assert parent_run_id == run.id

    conn = get(build_conn(), ~p"/api/v1/runs/#{run.id}/trace")

    assert %{
             "data" => %{
               "run" => %{"id" => run_id, "mission_id" => mission_id},
               "mission" => %{"id" => mission_id},
               "events" => [_ | _]
             }
           } = json_response(conn, 200)

    assert run_id == run.id
    assert mission_id == run.mission_id
  end

  test "workspace-scoped run routes reject foreign run ids", %{conn: conn} do
    workspace = workspace_fixture(%{name: "Ops", slug: "ops-run-scope"})
    other_workspace = workspace_fixture(%{name: "Other Ops", slug: "other-ops-run-scope"})

    {:ok, run} =
      Runtime.create_run(%{
        workspace_id: workspace.id,
        title: "Scoped run",
        goal: "Stay inside the workspace"
      })

    assert_error_sent 404, fn ->
      get(conn, ~p"/api/v1/workspaces/#{other_workspace.id}/runs/#{run.id}/trace")
    end
  end
end
