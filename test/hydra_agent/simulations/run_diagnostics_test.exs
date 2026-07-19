defmodule HydraAgent.Simulations.RunDiagnosticsTest do
  use HydraAgent.DataCase, async: false

  import HydraAgent.RuntimeFixtures

  alias HydraAgent.{Repo, Runtime, Simulations}
  alias HydraAgent.Simulations.{Blueprints, BudgetReservation, Engine}

  setup do
    workspace = workspace_fixture(%{name: "Support", slug: "run-support-diagnostics"})
    [general, _decision] = Blueprints.ensure_builtins!()

    {:ok, provider} =
      Runtime.create_provider(%{
        workspace_id: workspace.id,
        name: "Injected provider",
        kind: "mock",
        model: "mock-failure-v1",
        metadata: %{
          "mock_simulation_response" => "error",
          "capabilities" => %{
            "structured_generation" => true,
            "local_execution" => true
          }
        }
      })

    %{workspace: workspace, general: general, provider: provider}
  end

  test "summarizes provider fallbacks and terminal reservations without prompts or secrets",
       context do
    {:ok, simulation} =
      Simulations.create_simulation(context.workspace, nil, %{
        "title" => "Failure injection case",
        "question" => "How might a bounded intervention change participant behavior?",
        "blueprint_id" => context.general.id,
        "locale" => "en",
        "execution_mode" => "balanced",
        "budget_preset" => "standard",
        "population_size" => "40",
        "horizon" => "2 rounds",
        "inputs" => %{}
      })

    {:ok, record} = Simulations.create_simulation_run(simulation, nil)
    {:ok, record} = Engine.execute(record.id)
    record = Simulations.get_simulation_run_record!(record.id)
    diagnostic = Simulations.diagnose_run(record)

    assert diagnostic["severity"] == "attention"
    assert diagnostic["run"]["status"] == "completed"
    assert diagnostic["provider"]["fallbacks"] > 0
    assert diagnostic["provider"]["failure_reasons"]["mock_provider_failure"] > 0
    assert diagnostic["provider"]["fallback_reasons"]["provider_failure"] > 0
    assert diagnostic["budget"]["active_reservations"] == 0
    assert diagnostic["budget"]["status_counts"]["completed"] == record.model_call_count
    assert "check_provider_health_credentials_and_limits" in diagnostic["next_actions"]
    assert "review_deterministic_fallback_impact" in diagnostic["next_actions"]
    refute inspect(diagnostic) =~ "prompt_snapshot"
    refute inspect(diagnostic) =~ "short_rationale"

    assert Repo.all(BudgetReservation) |> Enum.all?(&(&1.status == "completed"))
  end
end
