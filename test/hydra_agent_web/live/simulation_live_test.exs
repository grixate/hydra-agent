defmodule HydraAgentWeb.SimulationLiveTest do
  use HydraAgentWeb.ConnCase

  import HydraAgent.RuntimeFixtures
  import Phoenix.LiveViewTest

  alias HydraAgent.Simulation

  test "creates a simulation from the control surface", %{conn: conn} do
    workspace = workspace_fixture(%{slug: "simulation-live-create"})

    {:ok, view, html} = live(conn, ~p"/control/simulations?workspace_id=#{workspace.id}")

    assert html =~ "Simulations"
    assert has_element?(view, "#simulation-create-form")

    view
    |> form("#simulation-create-form",
      simulation: %{
        title: "Live simulation",
        goal: "Create from the LiveView.",
        agent_count: "2",
        max_ticks: "3",
        max_budget_cents: "20",
        event_frequency: "0.5",
        cheap_provider: "",
        frontier_provider: ""
      }
    )
    |> render_submit()

    assert [simulation] = Simulation.list_simulations(workspace.id)
    assert simulation.title == "Live simulation"
    assert simulation.budget_plan["estimated_decisions"] == 6
    assert_patch(view, ~p"/control/simulations/#{simulation.id}?workspace_id=#{workspace.id}")
  end

  test "duplicates a simulation from the detail surface", %{conn: conn} do
    workspace = workspace_fixture(%{slug: "simulation-live-duplicate"})

    {:ok, simulation} =
      Simulation.create_simulation(%{
        workspace_id: workspace.id,
        title: "Source simulation",
        goal: "Duplicate from LiveView.",
        config: %{"agent_count" => 1, "max_ticks" => 1, "max_budget_cents" => 20}
      })

    {:ok, view, _html} =
      live(conn, ~p"/control/simulations/#{simulation.id}?workspace_id=#{workspace.id}")

    view |> element("button", "Duplicate") |> render_click()

    assert [copy, _source] = Simulation.list_simulations(workspace.id)
    assert copy.title == "Source simulation copy"
    assert_patch(view, ~p"/control/simulations/#{copy.id}?workspace_id=#{workspace.id}")
  end
end
