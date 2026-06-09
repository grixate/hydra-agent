defmodule HydraAgentWeb.SimulationControllerTest do
  use HydraAgentWeb.ConnCase

  import HydraAgent.RuntimeFixtures

  test "creates, estimates, lists, and replays workspace simulations", %{conn: conn} do
    workspace = workspace_fixture(%{slug: "simulation-controller"})

    conn =
      post(conn, ~p"/api/v1/workspaces/#{workspace.id}/simulations", %{
        title: "API rehearsal",
        goal: "Exercise the simulation API surface.",
        config: %{"agent_count" => 2, "max_ticks" => 1, "max_budget_cents" => 20}
      })

    assert %{"data" => %{"id" => simulation_id, "status" => "configuring"}} =
             json_response(conn, 201)

    conn =
      post(build_conn(), ~p"/api/v1/workspaces/#{workspace.id}/simulations/estimate", %{
        agent_count: 2,
        max_ticks: 1
      })

    assert %{"data" => %{"estimated_decisions" => 2}} = json_response(conn, 200)

    conn = get(build_conn(), ~p"/api/v1/workspaces/#{workspace.id}/simulations")
    assert %{"data" => [%{"id" => ^simulation_id}]} = json_response(conn, 200)

    conn =
      get(
        build_conn(),
        ~p"/api/v1/workspaces/#{workspace.id}/simulations/#{simulation_id}/replay"
      )

    assert %{"data" => %{"simulation" => %{"id" => ^simulation_id}, "ticks" => []}} =
             json_response(conn, 200)
  end

  test "duplicates and exports workspace simulations", %{conn: conn} do
    workspace = workspace_fixture(%{slug: "simulation-controller-export"})

    {:ok, simulation} =
      HydraAgent.Simulation.create_simulation(%{
        workspace_id: workspace.id,
        title: "Export source",
        goal: "Exercise duplicate and export endpoints.",
        config: %{"agent_count" => 1, "max_ticks" => 1, "max_budget_cents" => 20}
      })

    conn =
      post(
        conn,
        ~p"/api/v1/workspaces/#{workspace.id}/simulations/#{simulation.id}/duplicate",
        %{title: "Export copy"}
      )

    assert %{"data" => %{"id" => copy_id, "title" => "Export copy", "status" => "configuring"}} =
             json_response(conn, 201)

    conn =
      get(
        build_conn(),
        ~p"/api/v1/workspaces/#{workspace.id}/simulations/#{copy_id}/export"
      )

    assert %{
             "data" => %{
               "simulation" => %{"id" => ^copy_id},
               "agent_profiles" => [_profile],
               "budget_reservation" => %{"status" => "active"}
             }
           } = json_response(conn, 200)
  end

  test "rejects foreign workspace simulation access", %{conn: conn} do
    workspace = workspace_fixture(%{slug: "simulation-controller-scope"})
    other_workspace = workspace_fixture(%{slug: "simulation-controller-other"})

    {:ok, simulation} =
      HydraAgent.Simulation.create_simulation(%{
        workspace_id: workspace.id,
        title: "Scoped simulation",
        goal: "Should not be visible from another workspace.",
        config: %{"agent_count" => 1, "max_ticks" => 1, "max_budget_cents" => 10}
      })

    assert_error_sent 404, fn ->
      get(conn, ~p"/api/v1/workspaces/#{other_workspace.id}/simulations/#{simulation.id}")
    end
  end

  test "rejects report generation for non-terminal simulations", %{conn: conn} do
    workspace = workspace_fixture(%{slug: "simulation-controller-report-state"})

    {:ok, simulation} =
      HydraAgent.Simulation.create_simulation(%{
        workspace_id: workspace.id,
        title: "Running report guard",
        goal: "Reports should only summarize terminal simulations.",
        config: %{"agent_count" => 1, "max_ticks" => 1, "max_budget_cents" => 10}
      })

    conn = post(conn, ~p"/api/v1/workspaces/#{workspace.id}/simulations/#{simulation.id}/report")

    assert %{
             "errors" => %{
               "reason" => "simulation_not_reportable",
               "status" => "configuring"
             }
           } = json_response(conn, 409)
  end
end
