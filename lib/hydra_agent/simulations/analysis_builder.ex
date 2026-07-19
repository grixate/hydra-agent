defmodule HydraAgent.Simulations.AnalysisBuilder do
  @moduledoc """
  Builds the immutable, bounded Analysis Pack from authoritative Run records.

  The builder never calls a provider. It verifies the final recovery snapshot,
  derives every value deterministically, and publishes only stable references
  that a later Report is allowed to cite.
  """

  import Ecto.Query

  alias Decimal, as: D
  alias HydraAgent.Repo
  alias HydraAgent.Runtime.RunEvent

  alias HydraAgent.Simulations.{
    AnalysisPack,
    ContentHash,
    ResourceTransaction,
    RunDecision,
    RunDecisionAgent,
    RunSnapshot,
    SimulationRunRecord
  }

  alias HydraAgent.Simulations.Engine.RunStore

  @max_metrics 128
  @max_segments 96
  @max_timeline 48
  @max_resource_flows 96
  @max_pivotal_events 24
  @max_traces 32
  @max_decisions 96
  @max_grounding 240
  @max_reference_values 64

  def ensure_for_run(%SimulationRunRecord{} = record), do: ensure_for_run(record.id)

  def ensure_for_run(record_id) do
    case Repo.get_by(AnalysisPack, simulation_run_record_id: record_id) do
      %AnalysisPack{} = pack ->
        {:ok, pack}

      nil ->
        with {:ok, attrs} <- build(record_id),
             {:ok, pack} <- insert(attrs) do
          {:ok, pack}
        end
    end
  end

  def build(record_id) do
    record = load_record(record_id)

    with :ok <- completed(record),
         %RunSnapshot{} = initial <- snapshot(record.id, :initial),
         %RunSnapshot{} = final <- snapshot(record.id, :final),
         :ok <- RunStore.verify_snapshot(record, initial),
         :ok <- RunStore.verify_snapshot(record, final) do
      events = run_events(record)
      transactions = resource_transactions(record)
      decisions = run_decisions(record)
      state = final.payload
      initial_state = initial.payload

      metrics = metrics(record, state)
      segments = segments(state)
      timeline = timeline(state)
      resource_flows = resource_flows(transactions, state["agents"] || [])
      pivotal_events = pivotal_events(events, record.run_id)
      model_decisions = model_decisions(decisions)
      traces = representative_traces(record, initial_state, state, decisions)
      grounding = grounding_refs(record.context_pack)
      robustness = robustness(record, metrics)
      scenario_deltas = scenario_deltas(record, metrics)
      uncertainty = uncertainty(record, decisions, robustness)
      usage = usage(record, decisions, transactions, events)
      limitations = limitations(record, robustness)
      setup = setup(record)

      contract = %{
        "schema_version" => 1,
        "protocol_version" => "hydra-analysis/v1",
        "setup" => setup,
        "metrics" => metrics,
        "segments" => segments,
        "timeline" => timeline,
        "resource_flows" => resource_flows,
        "pivotal_events" => pivotal_events,
        "representative_traces" => traces,
        "model_decisions" => model_decisions,
        "scenario_deltas" => scenario_deltas,
        "robustness" => robustness,
        "uncertainty" => uncertainty,
        "grounding_refs" => grounding,
        "usage" => usage,
        "limitations" => limitations
      }

      reference_index = reference_index(contract)
      contract = Map.put(contract, "reference_index", reference_index)
      content_hash = ContentHash.digest(contract)

      {:ok,
       Map.merge(contract, %{
         "workspace_id" => record.workspace_id,
         "run_id" => record.run_id,
         "simulation_id" => record.simulation_id,
         "simulation_run_record_id" => record.id,
         "simulation_version_id" => record.simulation_version_id,
         "context_pack_id" => record.context_pack_id,
         "population_model_id" => record.population_model_id,
         "simulation_script_id" => record.simulation_script_id,
         "report_generation_cap" => 8,
         "content_hash" => content_hash,
         "generated_at" => DateTime.utc_now()
       })}
    else
      nil -> {:error, :run_snapshot_missing}
      {:error, _reason} = error -> error
    end
  end

  defp insert(attrs) do
    %AnalysisPack{}
    |> AnalysisPack.changeset(attrs)
    |> Repo.insert()
    |> case do
      {:ok, pack} ->
        {:ok, pack}

      {:error, changeset} ->
        case Repo.get_by(AnalysisPack,
               simulation_run_record_id: attrs["simulation_run_record_id"]
             ) do
          %AnalysisPack{} = pack -> {:ok, pack}
          nil -> {:error, changeset}
        end
    end
  end

  defp load_record(record_id) do
    SimulationRunRecord
    |> Repo.get!(record_id)
    |> Repo.preload(
      [
        :run,
        :simulation,
        :context_pack,
        :population_model,
        :simulation_script,
        :model_route_plan,
        :budget_plan,
        simulation_version: :blueprint_version
      ],
      in_parallel: false
    )
  end

  defp completed(%{run: %{status: "completed"}}), do: :ok
  defp completed(_record), do: {:error, :run_not_completed}

  defp snapshot(record_id, :initial) do
    RunSnapshot
    |> where([item], item.simulation_run_record_id == ^record_id)
    |> order_by([item], asc: item.round)
    |> limit(1)
    |> Repo.one()
  end

  defp snapshot(record_id, :final) do
    RunSnapshot
    |> where([item], item.simulation_run_record_id == ^record_id)
    |> order_by([item], desc: item.round)
    |> limit(1)
    |> Repo.one()
  end

  defp run_events(record) do
    RunEvent
    |> where([event], event.run_id == ^record.run_id)
    |> where([event], like(event.event_type, "simulation.%"))
    |> order_by([event], asc: event.sequence)
    |> Repo.all()
  end

  defp resource_transactions(record) do
    ResourceTransaction
    |> where([item], item.simulation_run_record_id == ^record.id)
    |> order_by([item], asc: item.sequence)
    |> Repo.all()
  end

  defp run_decisions(record) do
    RunDecision
    |> where([decision], decision.simulation_run_record_id == ^record.id)
    |> order_by([decision], asc: decision.sequence)
    |> Repo.all()
  end

  defp setup(record) do
    version = record.simulation_version
    blueprint = version.blueprint_version

    %{
      "ref" => "setup:run",
      "question" => version.question,
      "simulation_title" => version.title,
      "locale" => version.locale,
      "mode" => record.mode,
      "replay_kind" => record.replay_kind,
      "population_size" => record.population_model.population_size,
      "rounds_planned" => record.rounds_planned,
      "rounds_completed" => record.current_round,
      "seed" => record.seed,
      "engine_version" => record.engine_version,
      "pack_hash" => record.pack_hash,
      "result_hash" => record.result_hash,
      "decision_manifest_hash" => record.decision_manifest_hash,
      "simulation_version_hash" => version.content_hash,
      "blueprint_version" => blueprint.version,
      "blueprint_version_hash" => blueprint.content_hash,
      "context_pack_hash" => record.context_pack.content_hash,
      "population_model_hash" => record.population_model.content_hash,
      "simulation_script_hash" => record.simulation_script.content_hash,
      "model_route_plan_hash" => record.model_route_plan.content_hash,
      "budget_plan_hash" => record.budget_plan.content_hash
    }
  end

  defp metrics(record, state) do
    observations = List.wrap(state["observations"])
    definitions = get_in(record.simulation_script.script, ["observations", "metrics"]) || []
    by_id = Map.new(definitions, &{&1["id"], &1})
    ids = definitions |> Enum.map(& &1["id"]) |> Enum.reject(&is_nil/1)

    observation_metrics =
      ids
      |> Enum.map(fn id ->
        values =
          observations
          |> Enum.map(&get_in(&1, ["metrics", id]))
          |> Enum.filter(&is_number/1)

        definition = by_id[id] || %{}
        first = List.first(values) || 0
        final = List.last(values) || 0

        %{
          "ref" => "metric:#{id}",
          "id" => id,
          "kind" => definition["kind"] || "derived",
          "unit" => metric_unit(definition["kind"]),
          "first" => normalize_number(first),
          "final" => normalize_number(final),
          "change" => normalize_number(number(final) - number(first)),
          "minimum" => normalize_number(Enum.min(values, fn -> 0 end)),
          "maximum" => normalize_number(Enum.max(values, fn -> 0 end)),
          "mean" => normalize_number(mean(values)),
          "direction" => direction(first, final),
          "round_count" => length(values)
        }
      end)

    action_metrics =
      state
      |> Map.get("action_counts", %{})
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.map(fn {action, count} ->
        %{
          "ref" => "metric:action:#{action}",
          "id" => "action:#{action}",
          "kind" => "action_frequency",
          "unit" => "count",
          "final" => count,
          "share_of_actions" => ratio(count, Enum.sum(Map.values(state["action_counts"] || %{}))),
          "direction" => "observed"
        }
      end)

    (observation_metrics ++ action_metrics)
    |> Enum.uniq_by(& &1["ref"])
    |> Enum.take(@max_metrics)
  end

  defp segments(state) do
    agents = List.wrap(state["agents"])
    total = max(length(agents), 1)

    type_segments = grouped_segments(agents, "type", "type", total)
    archetype_segments = grouped_segments(agents, "archetype", "archetype", total)

    (type_segments ++ archetype_segments)
    |> Enum.sort_by(&{&1["kind"], &1["id"]})
    |> Enum.take(@max_segments)
  end

  defp grouped_segments(agents, field, kind, total) do
    agents
    |> Enum.group_by(&(&1[field] || "unknown"))
    |> Enum.map(fn {id, members} ->
      last_actions =
        members
        |> Enum.map(&get_in(&1, ["state", "last_action"]))
        |> Enum.reject(&is_nil/1)
        |> Enum.frequencies()
        |> Enum.sort_by(fn {action, count} -> {-count, action} end)
        |> Enum.take(8)
        |> Map.new()

      %{
        "ref" => "segment:#{kind}:#{id}",
        "id" => id,
        "kind" => kind,
        "count" => length(members),
        "share" => ratio(length(members), total),
        "last_actions" => last_actions,
        "state_means" => numeric_means(members, "state"),
        "attribute_means" => numeric_means(members, "attributes")
      }
    end)
  end

  defp numeric_means(members, field) do
    keys =
      members
      |> Enum.flat_map(fn member -> Map.keys(member[field] || %{}) end)
      |> Enum.uniq()
      |> Enum.sort()
      |> Enum.take(8)

    Map.new(keys, fn key ->
      values = members |> Enum.map(&get_in(&1, [field, key])) |> Enum.filter(&is_number/1)
      {key, if(values == [], do: nil, else: normalize_number(mean(values)))}
    end)
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp timeline(state) do
    state
    |> Map.get("observations", [])
    |> sample_evenly(@max_timeline)
    |> Enum.map(fn observation ->
      %{
        "ref" => "timeline:round:#{observation["round"]}",
        "round" => observation["round"],
        "metrics" =>
          observation
          |> Map.get("metrics", %{})
          |> Enum.sort_by(&elem(&1, 0))
          |> Enum.take(32)
          |> Map.new()
      }
    end)
  end

  defp resource_flows(transactions, agents) do
    type_by_agent = Map.new(agents, &{&1["id"], &1["type"]})

    transactions
    |> Enum.group_by(fn transaction ->
      {
        transaction.resource_id,
        transaction.operation,
        account_class(transaction.source_account, type_by_agent),
        account_class(transaction.destination_account, type_by_agent)
      }
    end)
    |> Enum.map(fn {{resource, operation, source, destination}, items} ->
      amount = Enum.reduce(items, D.new(0), &D.add(&1.amount, &2))

      %{
        "ref" => "resource_flow:#{resource}:#{operation}:#{source}:#{destination}",
        "resource" => resource,
        "operation" => operation,
        "source" => source,
        "destination" => destination,
        "transaction_count" => length(items),
        "amount" => D.to_string(amount, :normal),
        "first_round" => items |> Enum.map(& &1.round) |> Enum.min(),
        "last_round" => items |> Enum.map(& &1.round) |> Enum.max()
      }
    end)
    |> Enum.sort_by(fn flow ->
      {-decimal_float(flow["amount"]), flow["resource"], flow["operation"], flow["source"],
       flow["destination"]}
    end)
    |> Enum.take(@max_resource_flows)
  end

  defp account_class(nil, _type_by_agent), do: "world"

  defp account_class("agent:" <> agent_id, type_by_agent),
    do: "agent_type:#{type_by_agent[agent_id] || "unknown"}"

  defp account_class(account, _type_by_agent) when is_binary(account) do
    account |> String.split(":", parts: 2) |> List.first()
  end

  defp pivotal_events(events, run_id) do
    events
    |> Enum.filter(
      &(&1.event_type in ~w(simulation.world_event simulation.transition simulation.action_batch simulation.completed))
    )
    |> Enum.map(fn event ->
      %{
        "ref" => event_ref(run_id, event.sequence),
        "sequence" => event.sequence,
        "round" => event.round,
        "phase" => event.phase,
        "type" => event.event_type,
        "summary" => event.summary,
        "source_ref" => event.source_ref,
        "target_count" => event_target_count(event),
        "sampled_targets" => Enum.take(event.targets || [], 8),
        "payload" =>
          Map.take(event.payload || %{}, [
            "event_id",
            "transition_id",
            "action_id",
            "agent_count",
            "target_count",
            "effect_count",
            "matching_event_count",
            "state_changes",
            "stop_reason"
          ]),
        "priority" => event_priority(event)
      }
    end)
    |> Enum.sort_by(&{-&1["priority"], &1["sequence"]})
    |> Enum.take(@max_pivotal_events)
    |> Enum.sort_by(& &1["sequence"])
  end

  defp event_target_count(event) do
    payload = event.payload || %{}
    payload["target_count"] || payload["agent_count"] || length(event.targets || [])
  end

  defp event_priority(event) do
    base =
      case event.event_type do
        "simulation.completed" -> 100
        "simulation.world_event" -> 80
        "simulation.transition" -> 70
        "simulation.action_batch" -> 40
        _other -> 0
      end

    base + min(event_target_count(event), 10_000) / 10_000
  end

  defp model_decisions(decisions) do
    decisions
    |> Enum.sort_by(&{-decimal_float(&1.priority_score), &1.sequence})
    |> Enum.take(@max_decisions)
    |> Enum.sort_by(& &1.sequence)
    |> Enum.map(fn decision ->
      %{
        "ref" => "decision:#{decision.id}",
        "sequence" => decision.sequence,
        "round" => decision.round,
        "agent_type" => decision.agent_type,
        "archetype" => decision.archetype,
        "action_id" => decision.action_id,
        "reason_codes" => decision.reason_codes,
        "short_rationale" => decision.short_rationale,
        "uncertainty" => decimal_float(decision.uncertainty),
        "priority" => decimal_float(decision.priority_score),
        "source" => decision.source,
        "affected_agents" => decision.affected_agent_count,
        "reused_agents" => decision.reused_count,
        "fallback" => decision.fallback
      }
    end)
  end

  defp representative_traces(record, initial_state, final_state, decisions) do
    initial_agents = Map.new(initial_state["agents"] || [], &{&1["id"], &1})
    final_agents = final_state["agents"] || []
    final_by_id = Map.new(final_agents, &{&1["id"], &1})

    representative_ids =
      record.population_model.compile_summary
      |> Map.get("representatives", [])
      |> Enum.map(fn
        %{"id" => id} -> id
        id when is_binary(id) -> id
        _value -> nil
      end)
      |> Enum.reject(&is_nil/1)

    decision_ids = Enum.map(decisions, & &1.representative_agent_id)

    high_influence =
      final_agents
      |> Enum.sort_by(fn agent ->
        {-number(get_in(agent, ["attributes", "influence"])), agent["id"]}
      end)
      |> Enum.take(4)
      |> Enum.map(& &1["id"])

    selected_ids =
      (representative_ids ++ decision_ids ++ high_influence)
      |> Enum.uniq()
      |> Enum.filter(&Map.has_key?(final_by_id, &1))
      |> Enum.take(@max_traces)

    decision_refs = decision_refs_by_agent(record.id, selected_ids)

    Enum.map(selected_ids, fn agent_id ->
      initial = initial_agents[agent_id] || %{}
      final = final_by_id[agent_id] || %{}

      %{
        "ref" => "trace:#{agent_id}:final",
        "agent_id" => agent_id,
        "type" => final["type"],
        "archetype" => final["archetype"],
        "initial_state" => bounded_map(initial["state"]),
        "final_state" => bounded_map(final["state"]),
        "state_changes" => map_changes(initial["state"], final["state"]),
        "initial_resources" => bounded_map(initial["resources"]),
        "final_resources" => bounded_map(final["resources"]),
        "resource_changes" => map_changes(initial["resources"], final["resources"]),
        "decision_refs" => Map.get(decision_refs, agent_id, [])
      }
    end)
  end

  defp decision_refs_by_agent(_record_id, []), do: %{}

  defp decision_refs_by_agent(record_id, agent_ids) do
    RunDecisionAgent
    |> join(:inner, [mapping], decision in RunDecision,
      on: decision.id == mapping.simulation_run_decision_id
    )
    |> where(
      [mapping, decision],
      mapping.simulation_run_record_id == ^record_id and mapping.agent_id in ^agent_ids
    )
    |> order_by([mapping, decision], asc: decision.sequence)
    |> select([mapping, decision], {mapping.agent_id, decision.id})
    |> Repo.all()
    |> Enum.group_by(&elem(&1, 0), fn {_agent_id, decision_id} -> "decision:#{decision_id}" end)
  end

  defp grounding_refs(context_pack) do
    sources =
      Enum.map(context_pack.sources || [], fn source ->
        %{
          "ref" => "source:#{source["id"]}",
          "kind" => "source",
          "id" => source["id"],
          "title" => source["title"],
          "url" => source["url"],
          "published_at" => source["published_at"],
          "grounding_class" => source["grounding_class"],
          "status" => source["status"]
        }
      end)

    claims =
      Enum.map(context_pack.claims || [], fn claim ->
        %{
          "ref" => "claim:#{claim["id"]}",
          "kind" => "claim",
          "id" => claim["id"],
          "statement" => claim["statement"],
          "grounding_class" => claim["grounding_class"],
          "source_ref" => if(claim["source_id"], do: "source:#{claim["source_id"]}"),
          "confidence" => claim["confidence"]
        }
      end)

    assumptions =
      Enum.map(context_pack.assumptions || [], fn assumption ->
        %{
          "ref" => "assumption:#{assumption["id"]}",
          "kind" => "assumption",
          "id" => assumption["id"],
          "statement" => assumption["statement"]
        }
      end)

    gaps =
      Enum.map(context_pack.gaps || [], fn gap ->
        %{
          "ref" => "gap:#{gap["id"]}",
          "kind" => "gap",
          "id" => gap["id"],
          "code" => gap["kind"],
          "statement" => gap["statement"]
        }
      end)

    (sources ++ claims ++ assumptions ++ gaps)
    |> Enum.uniq_by(& &1["ref"])
    |> Enum.take(@max_grounding)
  end

  defp robustness(record, current_metrics) do
    previous =
      AnalysisPack
      |> where(
        [pack],
        pack.simulation_version_id == ^record.simulation_version_id and
          pack.simulation_script_id == ^record.simulation_script_id and
          pack.simulation_run_record_id != ^record.id
      )
      |> order_by([pack], desc: pack.inserted_at)
      |> limit(11)
      |> Repo.all()

    packs =
      [
        %{
          setup: %{"seed" => record.seed},
          metrics: current_metrics,
          content_hash: nil
        }
        | previous
      ]

    seeds = packs |> Enum.map(& &1.setup["seed"]) |> Enum.uniq()

    if length(seeds) >= 3 do
      ranges = metric_ranges(packs)

      %{
        "ref" => "robustness:seeds",
        "status" => "available",
        "seed_count" => length(seeds),
        "analysis_count" => length(packs),
        "metric_ranges" => ranges,
        "interpretation" => "cross_seed_range_not_confidence_interval"
      }
    else
      %{
        "ref" => "robustness:seeds",
        "status" => "insufficient_runs",
        "seed_count" => length(seeds),
        "analysis_count" => length(packs),
        "metric_ranges" => [],
        "interpretation" => "run_more_compatible_seeds"
      }
    end
  end

  defp metric_ranges(packs) do
    packs
    |> Enum.flat_map(fn pack ->
      Enum.map(pack.metrics || [], &{&1["id"], &1["final"]})
    end)
    |> Enum.filter(fn {_id, value} -> is_number(value) end)
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
    |> Enum.map(fn {id, values} ->
      %{
        "metric_ref" => "metric:#{id}",
        "minimum" => normalize_number(Enum.min(values)),
        "maximum" => normalize_number(Enum.max(values)),
        "mean" => normalize_number(mean(values)),
        "spread" => normalize_number(Enum.max(values) - Enum.min(values))
      }
    end)
    |> Enum.sort_by(& &1["metric_ref"])
    |> Enum.take(24)
  end

  defp scenario_deltas(%{replay_source_id: nil}, _metrics), do: []

  defp scenario_deltas(record, metrics) do
    case Repo.get_by(AnalysisPack, simulation_run_record_id: record.replay_source_id) do
      nil ->
        []

      source ->
        source_by_id = Map.new(source.metrics || [], &{&1["id"], &1})

        metrics
        |> Enum.flat_map(fn metric ->
          with %{} = source_metric <- source_by_id[metric["id"]],
               current when is_number(current) <- metric["final"],
               previous when is_number(previous) <- source_metric["final"] do
            [
              %{
                "ref" => "scenario_delta:#{source.run_id}:#{metric["id"]}",
                "metric_ref" => metric["ref"],
                "source_run_id" => to_string(source.run_id),
                "source_analysis_hash" => source.content_hash,
                "source_value" => previous,
                "current_value" => current,
                "delta" => normalize_number(current - previous),
                "replay_kind" => record.replay_kind
              }
            ]
          else
            _other -> []
          end
        end)
        |> Enum.take(32)
    end
  end

  defp uncertainty(record, decisions, robustness) do
    model = Enum.filter(decisions, &(&1.source == "model"))
    weighted_total = Enum.sum_by(model, &max(&1.affected_agent_count, 1))

    policy_uncertainty =
      if weighted_total == 0 do
        nil
      else
        Enum.sum_by(model, fn decision ->
          decimal_float(decision.uncertainty) * max(decision.affected_agent_count, 1)
        end) / weighted_total
      end

    fallback_count = Enum.count(decisions, &(is_binary(&1.fallback) and &1.fallback != ""))

    %{
      "ref" => "uncertainty:run",
      "interpretation" => "diagnostic_not_statistical_confidence",
      "context_confidence" => normalize_number(record.context_pack.confidence),
      "context_status" => record.context_pack.status,
      "policy_uncertainty_mean" => nullable_number(policy_uncertainty),
      "model_decision_count" => length(model),
      "recorded_decision_count" => length(decisions),
      "fallback_count" => fallback_count,
      "fallback_share" => ratio(fallback_count, max(length(decisions), 1)),
      "robustness_status" => robustness["status"],
      "robustness_seed_count" => robustness["seed_count"],
      "synthetic_population" => true
    }
  end

  defp usage(record, decisions, transactions, events) do
    runtime_seconds =
      if record.started_at && record.completed_at,
        do: DateTime.diff(record.completed_at, record.started_at, :millisecond) / 1_000,
        else: nil

    %{
      "ref" => "usage:run",
      "mode" => record.mode,
      "engine_version" => record.engine_version,
      "runtime_seconds" => nullable_number(runtime_seconds),
      "rounds" => record.current_round,
      "population_size" => record.population_model.population_size,
      "provider_calls_this_run" => record.result_summary["provider_calls_this_run"] || 0,
      "model_decisions_in_result" => record.model_call_count,
      "recorded_decisions" => length(decisions),
      "events" => length(events),
      "resource_transactions" => length(transactions),
      "budget" => record.budget_used,
      "pricing_status" => record.budget_plan.pricing_status,
      "currency" => record.budget_plan.currency
    }
  end

  defp limitations(record, robustness) do
    base = [
      limitation("synthetic_population", "directional_only", %{
        "population_size" => record.population_model.population_size
      }),
      limitation("not_observed_outcome", "validation_required", %{}),
      limitation("context_grounding", record.context_pack.status, %{
        "confidence" => normalize_number(record.context_pack.confidence),
        "source_count" => length(record.context_pack.sources || []),
        "assumption_count" => length(record.context_pack.assumptions || [])
      })
    ]

    base =
      if robustness["status"] == "available" do
        base
      else
        [
          limitation("seed_robustness", "insufficient_runs", %{
            "seed_count" => robustness["seed_count"]
          })
          | base
        ]
      end

    base =
      if record.budget_plan.pricing_status == "known" do
        base
      else
        [limitation("provider_price", "unverified", %{}) | base]
      end

    Enum.reverse(base)
  end

  defp limitation(code, status, details) do
    %{
      "ref" => "limitation:#{code}",
      "code" => code,
      "status" => status,
      "details" => details
    }
  end

  defp reference_index(contract) do
    items =
      [contract["setup"], contract["robustness"], contract["uncertainty"], contract["usage"]] ++
        contract["metrics"] ++
        contract["segments"] ++
        contract["timeline"] ++
        contract["resource_flows"] ++
        contract["pivotal_events"] ++
        contract["representative_traces"] ++
        contract["model_decisions"] ++
        contract["scenario_deltas"] ++
        contract["grounding_refs"] ++ contract["limitations"]

    items
    |> Enum.filter(&(is_map(&1) and is_binary(&1["ref"])))
    |> Enum.uniq_by(& &1["ref"])
    |> Map.new(fn item ->
      {item["ref"],
       %{
         "kind" => reference_kind(item["ref"]),
         "label" => reference_label(item),
         "numeric_values" => numeric_values(item)
       }}
    end)
  end

  defp reference_kind(ref), do: ref |> String.split(":", parts: 2) |> List.first()

  defp reference_label(item) do
    item["id"] || item["title"] || item["summary"] || item["code"] || item["ref"]
  end

  defp numeric_values(value) do
    value
    |> collect_numbers([])
    |> Enum.flat_map(&number_variants/1)
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.take(@max_reference_values)
  end

  defp collect_numbers(value, acc) when is_integer(value) or is_float(value), do: [value | acc]

  defp collect_numbers(%D{} = value, acc), do: [D.to_float(value) | acc]

  defp collect_numbers(value, acc) when is_binary(value) do
    if Regex.match?(~r/^-?\d+(?:\.\d+)?$/u, value),
      do: [decimal_float(value) | acc],
      else: acc
  end

  defp collect_numbers(value, acc) when is_list(value),
    do: Enum.reduce(value, acc, &collect_numbers/2)

  defp collect_numbers(value, acc) when is_map(value),
    do: Enum.reduce(Map.values(value), acc, &collect_numbers/2)

  defp collect_numbers(_value, acc), do: acc

  defp number_variants(value) do
    normalized = normalize_number(value)
    base = format_number(normalized)

    if is_number(normalized) and normalized >= 0 and normalized <= 1,
      do: [base, format_number(normalized * 100) <> "%"],
      else: [base]
  end

  defp event_ref(run_id, sequence),
    do: "event:run_#{run_id}:#{sequence |> to_string() |> String.pad_leading(6, "0")}"

  defp metric_unit("agent_fraction"), do: "fraction"
  defp metric_unit("action_count"), do: "count"
  defp metric_unit("relationship_count"), do: "count"
  defp metric_unit(_kind), do: "value"

  defp direction(first, final) do
    delta = number(final) - number(first)

    cond do
      delta > 1.0e-9 -> "increased"
      delta < -1.0e-9 -> "decreased"
      true -> "stable"
    end
  end

  defp sample_evenly(items, maximum) when length(items) <= maximum, do: items

  defp sample_evenly(items, maximum) do
    last = length(items) - 1

    0..(maximum - 1)
    |> Enum.map(fn index -> round(index * last / (maximum - 1)) end)
    |> Enum.uniq()
    |> Enum.map(&Enum.at(items, &1))
  end

  defp bounded_map(value) when is_map(value) do
    value |> Enum.sort_by(&elem(&1, 0)) |> Enum.take(16) |> Map.new()
  end

  defp bounded_map(_value), do: %{}

  defp map_changes(initial, final) do
    initial = initial || %{}
    final = final || %{}

    (Map.keys(initial) ++ Map.keys(final))
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.flat_map(fn key ->
      if initial[key] == final[key],
        do: [],
        else: [%{"key" => key, "from" => initial[key], "to" => final[key]}]
    end)
    |> Enum.take(16)
  end

  defp mean([]), do: 0
  defp mean(values), do: Enum.sum(values) / length(values)

  defp ratio(_numerator, 0), do: 0.0
  defp ratio(numerator, denominator), do: normalize_number(numerator / denominator)

  defp number(value) when is_integer(value) or is_float(value), do: value
  defp number(%D{} = value), do: D.to_float(value)

  defp number(value) when is_binary(value) do
    case Float.parse(value) do
      {parsed, ""} -> parsed
      _other -> 0
    end
  end

  defp number(_value), do: 0

  defp nullable_number(nil), do: nil
  defp nullable_number(value), do: normalize_number(value)

  defp normalize_number(value) when is_integer(value), do: value
  defp normalize_number(value) when is_float(value), do: Float.round(value, 6)
  defp normalize_number(%D{} = value), do: value |> D.to_float() |> normalize_number()
  defp normalize_number(value), do: value

  defp decimal_float(%D{} = value), do: D.to_float(value)
  defp decimal_float(value) when is_integer(value) or is_float(value), do: value * 1.0

  defp decimal_float(value) when is_binary(value) do
    case Float.parse(value) do
      {parsed, _rest} -> parsed
      :error -> 0.0
    end
  end

  defp decimal_float(_value), do: 0.0

  defp format_number(value) when is_integer(value), do: Integer.to_string(value)

  defp format_number(value) when is_float(value) do
    value
    |> Float.round(6)
    |> :erlang.float_to_binary([:compact, decimals: 6])
  end
end
