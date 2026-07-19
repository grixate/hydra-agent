defmodule HydraAgentWeb.SimulationDiagnosticsControllerTest do
  use HydraAgentWeb.ConnCase, async: false

  import HydraAgent.RuntimeFixtures

  alias HydraAgent.Simulations
  alias HydraAgent.Simulations.{Blueprints, Engine}

  test "admin diagnostic download is bounded to the Simulation workspace", %{conn: conn} do
    workspace = workspace_fixture(%{name: "Support UI", slug: "support-diagnostic-ui"})
    other = workspace_fixture(%{name: "Other", slug: "support-diagnostic-other"})
    [general, _decision] = Blueprints.ensure_builtins!()

    {:ok, simulation} =
      Simulations.create_simulation(workspace, nil, %{
        "title" => "Support case",
        "question" => "How might a bounded intervention change participant behavior?",
        "blueprint_id" => general.id,
        "locale" => "en",
        "execution_mode" => "quick",
        "population_size" => "24",
        "horizon" => "2 rounds",
        "inputs" => %{}
      })

    {:ok, record} = Simulations.create_quick_run(simulation, nil)
    {:ok, record} = Engine.execute(record.id)

    response =
      get(
        conn,
        "/simulations/#{simulation.id}/runs/#{record.id}/diagnostics.json?workspace_id=#{workspace.id}&locale=en"
      )

    diagnostic = response(response, 200) |> Jason.decode!()
    assert diagnostic["severity"] == "ok"
    assert diagnostic["run"]["result_hash"] == record.result_hash
    assert get_resp_header(response, "cache-control") == ["private, no-store"]
    assert get_resp_header(response, "x-content-type-options") == ["nosniff"]
    assert hd(get_resp_header(response, "content-disposition")) =~ "hydra-run-diagnostic-"

    denied =
      conn
      |> recycle()
      |> get(
        "/simulations/#{simulation.id}/runs/#{record.id}/diagnostics.json?workspace_id=#{other.id}&locale=en"
      )

    assert denied.status == 404
  end
end
