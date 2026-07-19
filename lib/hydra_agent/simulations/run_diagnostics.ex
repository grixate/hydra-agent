defmodule HydraAgent.Simulations.RunDiagnostics do
  @moduledoc "Privacy-safe provider, budget, and recovery diagnosis for a Simulation Run."

  import Ecto.Query

  alias HydraAgent.Repo
  alias HydraAgent.Runtime.RunEvent

  alias HydraAgent.Simulations.{
    BudgetReservation,
    ContentHash,
    RunDecision,
    RunSnapshot,
    SimulationReport,
    SimulationRunRecord
  }

  def build(%SimulationRunRecord{} = record) do
    record = Repo.preload(record, [:run, :budget_plan, :model_route_plan], in_parallel: false)
    reservations = reservations(record.id)
    decisions = decisions(record.id)
    reports = reports(record.id)
    snapshots = snapshots(record.id)
    event_types = event_types(record.run_id)
    reasons = failure_reasons(record, reservations, decisions, reports)
    active_reservations = Enum.count(reservations, &(&1.status == "reserved"))

    diagnosis = %{
      "schema_version" => 1,
      "protocol_version" => "hydra-run-diagnostic/v1",
      "support_code" => support_code(record),
      "run" => %{
        "record_id" => to_string(record.id),
        "run_id" => to_string(record.run_id),
        "simulation_id" => to_string(record.simulation_id),
        "workspace_id" => to_string(record.workspace_id),
        "status" => record.run.status,
        "mode" => record.mode,
        "replay_kind" => record.replay_kind,
        "engine_version" => record.engine_version,
        "seed" => record.seed,
        "rounds" => %{"completed" => record.current_round, "planned" => record.rounds_planned},
        "recoveries" => record.recovery_count,
        "failure_code" => map_value(record.failure, "code"),
        "pack_hash" => record.pack_hash,
        "result_hash" => record.result_hash
      },
      "provider" => %{
        "routes" => public_routes(record.model_route_snapshot),
        "model_calls" => record.model_call_count,
        "fallbacks" => record.fallback_count,
        "decision_sources" => frequencies(decisions, & &1.source),
        "failure_reasons" => reasons.provider,
        "fallback_reasons" => reasons.fallback
      },
      "budget" => %{
        "pricing_status" => record.budget_plan.pricing_status,
        "hard_model_call_cap" => record.budget_plan.hard_model_call_cap,
        "hard_runtime_seconds" => record.budget_plan.hard_runtime_seconds,
        "status_counts" => frequencies(reservations, & &1.status),
        "active_reservations" => active_reservations,
        "failure_reasons" => reasons.budget,
        "used" =>
          Map.take(
            record.budget_used || %{},
            ~w(model_calls input_tokens output_tokens cost currency)
          )
      },
      "recovery" => %{
        "snapshot_count" => length(snapshots),
        "latest_committed_round" => snapshots |> List.last() |> value(:round),
        "latest_event_sequence" => snapshots |> List.last() |> value(:event_sequence),
        "latest_state_hash" => snapshots |> List.last() |> value(:state_hash),
        "events" => frequencies(event_types, & &1)
      },
      "reports" => %{
        "status_counts" => frequencies(reports, & &1.status),
        "failure_reasons" => reasons.report
      }
    }

    Map.merge(diagnosis, attention(record, active_reservations, reasons))
  end

  defp reservations(record_id) do
    BudgetReservation
    |> where([item], item.simulation_run_record_id == ^record_id)
    |> order_by([item], asc: item.id)
    |> Repo.all()
  end

  defp decisions(record_id) do
    RunDecision
    |> where([item], item.simulation_run_record_id == ^record_id)
    |> order_by([item], asc: item.sequence)
    |> Repo.all()
  end

  defp reports(record_id) do
    SimulationReport
    |> where([item], item.simulation_run_record_id == ^record_id)
    |> order_by([item], asc: item.version)
    |> Repo.all()
  end

  defp snapshots(record_id) do
    RunSnapshot
    |> where([item], item.simulation_run_record_id == ^record_id)
    |> order_by([item], asc: item.round)
    |> select([item], %{
      round: item.round,
      event_sequence: item.event_sequence,
      state_hash: item.state_hash
    })
    |> Repo.all()
  end

  defp event_types(run_id) do
    RunEvent
    |> where(
      [item],
      item.run_id == ^run_id and
        item.event_type in [
          "simulation.recovered",
          "simulation.failed",
          "simulation.canceled",
          "simulation.completed"
        ]
    )
    |> select([item], item.event_type)
    |> Repo.all()
  end

  defp failure_reasons(record, reservations, decisions, reports) do
    provider =
      reservations
      |> Enum.map(&get_in(&1.metadata || %{}, ["provider_failure", "reason"]))
      |> compact_frequencies()

    fallback =
      decisions
      |> Enum.map(&map_value(&1.metadata, "failure"))
      |> compact_frequencies()

    budget =
      reservations
      |> Enum.map(&map_value(&1.metadata, "rejection_reason"))
      |> compact_frequencies()

    report =
      reports
      |> Enum.map(&map_value(&1.failure, "code"))
      |> compact_frequencies()

    run = compact_frequencies([map_value(record.failure, "code")])
    %{provider: provider, fallback: fallback, budget: budget, report: report, run: run}
  end

  defp attention(record, active_reservations, reasons) do
    actions =
      []
      |> maybe_action(record.run.status == "failed", "inspect_last_snapshot_before_rerun")
      |> maybe_action(active_reservations > 0, "reconcile_reserved_provider_requests")
      |> maybe_action(
        reasons.provider != %{} or reasons.fallback != %{},
        "check_provider_health_credentials_and_limits"
      )
      |> maybe_action(reasons.budget != %{}, "review_hard_budget_and_price_snapshot")
      |> maybe_action(record.fallback_count > 0, "review_deterministic_fallback_impact")
      |> maybe_action(reasons.report != %{}, "retry_report_without_rerunning_simulation")
      |> then(fn actions -> if actions == [], do: ["no_action_required"], else: actions end)

    severity =
      cond do
        record.run.status == "failed" -> "blocked"
        actions == ["no_action_required"] -> "ok"
        true -> "attention"
      end

    %{
      "severity" => severity,
      "next_actions" => actions,
      "run_failure_reasons" => reasons.run
    }
  end

  defp public_routes(routes) when is_map(routes) do
    Map.new(routes, fn {role, route} ->
      {to_string(role),
       if(is_map(route),
         do: Map.take(route, ~w(selection status provider model local route_version)),
         else: %{"status" => "invalid"}
       )}
    end)
  end

  defp public_routes(_routes), do: %{}

  defp support_code(record) do
    ContentHash.digest(%{
      "run_record_id" => record.id,
      "run_id" => record.run_id,
      "pack_hash" => record.pack_hash,
      "engine_version" => record.engine_version
    })
    |> String.slice(0, 16)
  end

  defp frequencies(values, fun) do
    values
    |> Enum.map(fun)
    |> compact_frequencies()
  end

  defp compact_frequencies(values) do
    values
    |> Enum.filter(&(is_binary(&1) and &1 != ""))
    |> Enum.frequencies()
    |> Enum.sort_by(&elem(&1, 0))
    |> Map.new()
  end

  defp maybe_action(actions, true, action), do: actions ++ [action]
  defp maybe_action(actions, false, _action), do: actions

  defp map_value(map, key) when is_map(map) do
    case Map.get(map, key) do
      value when is_binary(value) -> String.slice(value, 0, 120)
      _value -> nil
    end
  end

  defp map_value(_map, _key), do: nil

  defp value(nil, _key), do: nil
  defp value(map, key), do: Map.get(map, key)
end
