defmodule HydraAgent.Simulations.BalancedCognitionTest do
  use HydraAgent.DataCase, async: false

  import Ecto.Query
  import HydraAgent.RuntimeFixtures

  alias HydraAgent.{Repo, Runtime, Simulations}
  alias HydraAgent.Simulations.{Blueprints, BudgetReservation, RunDecision, RunDecisionAgent}
  alias HydraAgent.Simulations.Engine

  setup do
    workspace = workspace_fixture(%{name: "Balanced Engine", slug: "balanced-engine"})
    [general, _decision_replay] = Blueprints.ensure_builtins!()

    assert {:ok, provider} =
             Runtime.create_provider(%{
               workspace_id: workspace.id,
               name: "Local cognition",
               kind: "mock",
               model: "mock-structured-v1",
               enabled: true,
               metadata: %{
                 "capabilities" => %{
                   "structured_generation" => true,
                   "local_execution" => true,
                   "deterministic_seed" => true
                 }
               }
             })

    %{workspace: workspace, general: general, provider: provider}
  end

  test "Balanced mode records bounded representative decisions and completes deterministically",
       context do
    simulation = balanced_simulation(context, 60, "3 rounds")

    assert Enum.any?(simulation.active_script.script["policies"], &(&1["kind"] == "hybrid"))
    assert {:ok, _summary} = Simulations.run_readiness(simulation)
    assert {:ok, record} = Simulations.create_simulation_run(simulation, nil)
    assert record.mode == "balanced"
    assert record.engine_version == "hydra-balanced/v1"

    assert {:ok, completed} = Engine.execute(record.id)
    completed = Simulations.get_simulation_run_record!(completed.id)

    assert completed.run.status == "completed"
    assert completed.current_round == 3
    assert completed.model_call_count in 1..80
    assert completed.model_call_count == completed.budget_used["model_calls"]
    assert byte_size(completed.decision_manifest_hash) == 64

    decisions =
      RunDecision
      |> where([decision], decision.simulation_run_record_id == ^completed.id)
      |> preload(:agents)
      |> Repo.all()

    assert decisions != []
    assert Enum.count(decisions, &(&1.source == "model")) == completed.model_call_count
    assert Enum.all?(decisions, &(&1.action_id in (&1.prompt_snapshot["allowed_actions"] || [])))
    assert Enum.all?(decisions, &(&1.affected_agent_count == length(&1.agents)))
    assert Repo.aggregate(RunDecisionAgent, :count) > 0

    assert Repo.all(
             from(reservation in BudgetReservation,
               where: reservation.simulation_run_record_id == ^completed.id,
               select: reservation.status
             )
           )
           |> Enum.all?(&(&1 in ~w(completed released rejected)))
  end

  test "exact replay reproduces the decision manifest and result without provider calls",
       context do
    simulation = balanced_simulation(context, 50, "2 rounds")
    assert {:ok, original} = Simulations.create_simulation_run(simulation, nil)
    assert {:ok, original} = Engine.execute(original.id)

    assert {:ok, replay} = Simulations.create_exact_replay(original, nil)
    assert replay.replay_kind == "exact_replay"
    assert replay.replay_source_id == original.id
    assert replay.pack_hash == original.pack_hash

    assert {:ok, replay} = Engine.execute(replay.id)
    replay = Simulations.get_simulation_run_record!(replay.id)

    assert replay.result_hash == original.result_hash
    assert replay.final_state_hash == original.final_state_hash
    assert replay.decision_manifest_hash == original.decision_manifest_hash
    assert replay.model_call_count == 0
    assert replay.budget_used["model_calls"] == 0

    replay_decisions =
      Repo.all(
        from(decision in RunDecision,
          where: decision.simulation_run_record_id == ^replay.id,
          order_by: decision.sequence
        )
      )

    assert replay_decisions != []
    assert Enum.all?(replay_decisions, &(&1.source == "exact_replay"))
    assert Enum.all?(replay_decisions, &is_integer(&1.replay_source_decision_id))

    assert {:ok, fresh} = Simulations.create_fresh_rerun(original, nil)
    assert fresh.replay_kind == "fresh_rerun"
    assert fresh.seed == original.seed + 1
    refute fresh.pack_hash == original.pack_hash

    assert {:ok, fresh} = Engine.execute(fresh.id)
    refute fresh.result_hash == original.result_hash
  end

  test "invalid provider output closes the budget and applies a recorded safe fallback",
       context do
    simulation = balanced_simulation(context, 40, "2 rounds")

    context.provider
    |> Ecto.Changeset.change(
      metadata: Map.put(context.provider.metadata, "mock_simulation_response", "invalid")
    )
    |> Repo.update!()

    assert {:ok, record} = Simulations.create_simulation_run(simulation, nil)
    assert {:ok, completed} = Engine.execute(record.id)
    completed = Simulations.get_simulation_run_record!(completed.id)

    assert completed.run.status == "completed"
    assert completed.model_call_count > 0
    assert completed.fallback_count > 0

    decisions =
      Repo.all(
        from(decision in RunDecision,
          where: decision.simulation_run_record_id == ^completed.id
        )
      )

    assert decisions != []
    assert Enum.all?(decisions, &(&1.source == "deterministic_rule"))
    assert Enum.all?(decisions, &(&1.fallback == "deterministic_rule"))

    reservations =
      Repo.all(
        from(reservation in BudgetReservation,
          where: reservation.simulation_run_record_id == ^completed.id
        )
      )

    assert Enum.all?(reservations, &(&1.status == "completed"))
    assert Enum.all?(reservations, &(&1.actual_input_tokens == &1.max_input_tokens))
    assert Enum.all?(reservations, &(&1.metadata["usage_accounting"] == "reserved_envelope"))
  end

  @tag timeout: 120_000
  @tag :pilot_performance
  test "5,000 agents over 12 rounds stay within the decision cap and engine target", context do
    simulation = balanced_simulation(context, 5_000, "12 rounds")
    assert {:ok, record} = Simulations.create_simulation_run(simulation, nil)

    started_at = System.monotonic_time(:millisecond)
    assert {:ok, completed} = Engine.execute(record.id)
    elapsed = System.monotonic_time(:millisecond) - started_at
    completed = Simulations.get_simulation_run_record!(completed.id)

    assert completed.current_round == 12
    assert completed.model_call_count <= 80
    assert elapsed < 60_000

    assert Repo.all(
             from(reservation in BudgetReservation,
               where: reservation.simulation_run_record_id == ^completed.id,
               select: reservation.status
             )
           )
           |> Enum.all?(&(&1 in ~w(completed released rejected)))

    maximum_agent_decisions =
      RunDecisionAgent
      |> where([mapping], mapping.simulation_run_record_id == ^completed.id)
      |> group_by([mapping], mapping.agent_id)
      |> select([mapping], count(mapping.id))
      |> Repo.all()
      |> Enum.max(fn -> 0 end)

    assert maximum_agent_decisions <= 2

    assert Repo.exists?(
             from(decision in RunDecision,
               where:
                 decision.simulation_run_record_id == ^completed.id and
                   decision.affected_agent_count > 1
             )
           )
  end

  defp balanced_simulation(%{workspace: workspace, general: general}, size, horizon) do
    assert {:ok, simulation} =
             Simulations.create_simulation(workspace, nil, %{
               "question" => "How might a bounded intervention change participant behavior?",
               "blueprint_id" => general.id,
               "locale" => "en",
               "execution_mode" => "balanced",
               "budget_preset" => "standard",
               "population_size" => Integer.to_string(size),
               "horizon" => horizon,
               "inputs" => %{}
             })

    simulation
  end
end
