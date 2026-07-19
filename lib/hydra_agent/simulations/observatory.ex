defmodule HydraAgent.Simulations.Observatory do
  @moduledoc """
  Builds the compact, deterministic Observatory protocol and bounded agent detail.

  The initial payload contains aggregates and representative samples only. Full
  agent state is read on demand from immutable Run snapshots.
  """

  import Ecto.Query

  alias Decimal, as: D
  alias HydraAgent.Repo

  alias HydraAgent.Simulations.{
    AnalysisPack,
    ContentHash,
    PersonaRenderer,
    RunDecision,
    RunDecisionAgent,
    RunSnapshot,
    SimulationRunRecord
  }

  @protocol "hydra-observatory/v1"
  @detail_protocol "hydra-observatory-agent/v1"
  @max_metrics 8
  @max_timeline 48
  @max_flows 48
  @max_events 20
  @max_drivers 16
  @max_samples 32
  @max_relationships 24
  @max_history 64
  @max_decisions 32
  @max_grounding 24

  def payload(%AnalysisPack{} = pack, comparison_pack \\ nil) do
    pack = load_pack(pack.id)

    with {:ok, comparison_pack} <- valid_comparison(pack, comparison_pack) do
      metric_ids = metric_ids(pack)
      aggregates = final_aggregates(pack.simulation_run_record_id)

      contract = %{
        "protocol_version" => @protocol,
        "run" => run_summary(pack),
        "main_result" => main_result(pack),
        "state" => state_lens(pack, aggregates, comparison_pack),
        "flow" => flow_lens(pack, metric_ids, comparison_pack),
        "explain" => explain_lens(pack, comparison_pack),
        "comparison" => comparison(pack, comparison_pack)
      }

      content_hash = ContentHash.digest(contract)
      encoded = Jason.encode!(contract)

      {:ok,
       Map.merge(contract, %{
         "content_hash" => content_hash,
         "payload_bytes" => byte_size(encoded),
         "compressed_bytes" => encoded |> :zlib.gzip() |> byte_size()
       })}
    end
  end

  def agent_detail(%SimulationRunRecord{} = record, agent_id, locale \\ "en") do
    record = load_record(record.id)

    with :ok <- completed_record(record),
         :ok <- valid_agent_id(agent_id),
         history when history != [] <- agent_history(record.id, agent_id),
         final when is_map(final) <- history |> List.last() |> Map.get("agent") do
      relationships = agent_relationships(record.id, agent_id)
      decisions = agent_decisions(record.id, agent_id)
      representative = representative(record, agent_id)
      persona = persona(representative, locale)
      grounding = grounding(record, representative)

      contract = %{
        "protocol_version" => @detail_protocol,
        "run_record_id" => to_string(record.id),
        "agent" => bounded_agent(final),
        "history" => Enum.map(history, &history_row/1),
        "relationships" => Enum.map(relationships, &relationship(&1, agent_id)),
        "decisions" => Enum.map(decisions, &decision/1),
        "persona" => persona,
        "grounding" => grounding,
        "synthetic" => true
      }

      {:ok, Map.put(contract, "content_hash", ContentHash.digest(contract))}
    else
      [] -> {:error, :agent_not_found}
      nil -> {:error, :agent_not_found}
      {:error, _reason} = error -> error
    end
  end

  defp load_pack(id) do
    AnalysisPack
    |> Repo.get!(id)
    |> Repo.preload(
      [
        simulation_run_record: [
          :run,
          :simulation,
          :population_model,
          :simulation_script,
          :model_route_plan,
          :budget_plan,
          :context_pack
        ]
      ],
      in_parallel: false
    )
  end

  defp load_record(id) do
    SimulationRunRecord
    |> Repo.get!(id)
    |> Repo.preload(
      [:run, :simulation, :population_model, :simulation_script, :context_pack],
      in_parallel: false
    )
  end

  defp valid_comparison(_pack, nil), do: {:ok, nil}

  defp valid_comparison(pack, %AnalysisPack{} = comparison_pack) do
    comparison_pack = load_pack(comparison_pack.id)

    if comparison_pack.simulation_id == pack.simulation_id and comparison_pack.id != pack.id,
      do: {:ok, comparison_pack},
      else: {:error, :invalid_comparison}
  end

  defp valid_agent_id(agent_id) when is_binary(agent_id) do
    if String.length(agent_id) in 1..160 and
         Regex.match?(~r/^[\p{L}\p{N}._:-]+$/u, agent_id),
       do: :ok,
       else: {:error, :invalid_agent_id}
  end

  defp valid_agent_id(_agent_id), do: {:error, :invalid_agent_id}

  defp completed_record(%SimulationRunRecord{run: %{status: "completed"}}), do: :ok
  defp completed_record(_record), do: {:error, :run_not_completed}

  defp run_summary(pack) do
    record = pack.simulation_run_record
    compile = record.population_model.compile_summary || %{}

    %{
      "run_id" => to_string(pack.run_id),
      "run_record_id" => to_string(record.id),
      "analysis_hash" => pack.content_hash,
      "result_hash" => record.result_hash,
      "mode" => record.mode,
      "replay_kind" => record.replay_kind,
      "seed" => record.seed,
      "rounds" => record.current_round,
      "population_size" => pack.usage["population_size"],
      "model_decisions" => pack.usage["model_decisions_in_result"] || 0,
      "recorded_decisions" => pack.usage["recorded_decisions"] || 0,
      "representative_personas" => compile["representative_count"] || 0,
      "relationship_count" => compile["relationship_count"] || 0
    }
  end

  defp main_result(pack) do
    metric =
      Enum.find(pack.metrics, &(&1["kind"] != "action_frequency" and is_number(&1["final"]))) ||
        Enum.find(pack.metrics, &is_number(&1["final"]))

    case metric do
      nil ->
        %{"status" => "recorded", "ref" => "setup:run"}

      metric ->
        Map.take(metric, ["ref", "id", "kind", "unit", "first", "final", "change", "direction"])
    end
  end

  defp state_lens(pack, aggregates, comparison_pack) do
    comparison_segments =
      if comparison_pack,
        do: Map.new(comparison_pack.segments, &{{&1["kind"], &1["id"]}, &1}),
        else: %{}

    cohorts =
      pack.segments
      |> Enum.filter(&(&1["kind"] in ~w(type archetype)))
      |> Enum.map(fn segment ->
        baseline = comparison_segments[{segment["kind"], segment["id"]}]

        segment
        |> Map.take([
          "ref",
          "id",
          "kind",
          "count",
          "share",
          "last_actions",
          "state_means",
          "attribute_means"
        ])
        |> Map.merge(stable_position("cohort:#{segment["kind"]}:#{segment["id"]}"))
        |> maybe_comparison("baseline_count", baseline && baseline["count"])
        |> maybe_comparison("baseline_share", baseline && baseline["share"])
        |> maybe_delta("share_delta", segment["share"], baseline && baseline["share"])
      end)

    %{
      "cohorts" => cohorts,
      "state_distribution" => aggregates["states"] || [],
      "resources" => aggregates["resources"] || [],
      "relationship_types" => aggregates["relationships"] || [],
      "samples" => samples(pack),
      "scale" => %{
        "population_size" => pack.usage["population_size"],
        "rendered_samples" => min(length(pack.representative_traces), @max_samples),
        "aggregation" => "cohort_density"
      }
    }
  end

  defp samples(pack) do
    representatives =
      pack.simulation_run_record.population_model.compile_summary
      |> Map.get("representatives", [])
      |> Map.new(&{&1["agent_id"], &1})

    pack.representative_traces
    |> Enum.take(@max_samples)
    |> Enum.map(fn trace ->
      representative = representatives[trace["agent_id"]] || %{}

      %{
        "id" => trace["agent_id"],
        "ref" => trace["ref"],
        "type" => trace["type"],
        "archetype" => trace["archetype"],
        "state_change_count" => length(trace["state_changes"] || []),
        "resource_change_count" => length(trace["resource_changes"] || []),
        "influence" => get_in(representative, ["attributes", "influence"]),
        "persona_available" => map_size(representative) > 0
      }
      |> Map.merge(stable_position("agent:#{trace["agent_id"]}"))
    end)
  end

  defp flow_lens(pack, metric_ids, comparison_pack) do
    %{
      "metric_ids" => metric_ids,
      "timeline" => compact_timeline(pack.timeline, metric_ids),
      "baseline_timeline" =>
        if(comparison_pack,
          do: compact_timeline(comparison_pack.timeline, metric_ids),
          else: []
        ),
      "resource_flows" => compact_flows(pack.resource_flows, comparison_pack),
      "pivotal_events" =>
        pack.pivotal_events
        |> Enum.take(@max_events)
        |> Enum.map(&Map.put(&1, "summary", event_summary(&1))),
      "actions" =>
        pack.metrics
        |> Enum.filter(&(&1["kind"] == "action_frequency"))
        |> Enum.take(16)
        |> Enum.map(&Map.take(&1, ["ref", "id", "final", "share_of_actions"]))
    }
  end

  defp metric_ids(pack) do
    pack.metrics
    |> Enum.filter(&(&1["kind"] != "action_frequency"))
    |> Enum.map(& &1["id"])
    |> Enum.take(@max_metrics)
  end

  defp compact_timeline(timeline, metric_ids) do
    timeline
    |> Enum.take(@max_timeline)
    |> Enum.map(fn item ->
      %{
        "round" => item["round"],
        "ref" => item["ref"],
        "metrics" => Map.take(item["metrics"] || %{}, metric_ids)
      }
    end)
  end

  defp compact_flows(flows, comparison_pack) do
    baseline =
      if comparison_pack,
        do: Map.new(comparison_pack.resource_flows, &{flow_key(&1), &1}),
        else: %{}

    flows
    |> Enum.take(@max_flows)
    |> Enum.map(fn flow ->
      comparison = baseline[flow_key(flow)]

      flow
      |> Map.take([
        "ref",
        "resource",
        "operation",
        "source",
        "destination",
        "transaction_count",
        "amount",
        "first_round",
        "last_round"
      ])
      |> maybe_comparison("baseline_amount", comparison && comparison["amount"])
      |> maybe_delta(
        "amount_delta",
        number(flow["amount"]),
        comparison && number(comparison["amount"])
      )
    end)
  end

  defp flow_key(flow),
    do: {flow["resource"], flow["operation"], flow["source"], flow["destination"]}

  defp explain_lens(pack, comparison_pack) do
    %{
      "modeled_drivers" => modeled_drivers(pack, comparison_pack),
      "model_decisions" =>
        pack.model_decisions
        |> Enum.sort_by(&{-number(&1["affected_agents"]), &1["sequence"]})
        |> Enum.take(16),
      "grounding" => Enum.take(pack.grounding_refs, @max_grounding),
      "uncertainty" => pack.uncertainty,
      "robustness" => pack.robustness,
      "limitations" => pack.limitations,
      "representative_traces" => Enum.take(pack.representative_traces, @max_samples)
    }
  end

  defp modeled_drivers(pack, comparison_pack) do
    population = max(pack.usage["population_size"] || 1, 1)

    event_drivers =
      Enum.map(pack.pivotal_events, fn event ->
        %{
          "ref" => event["ref"],
          "kind" => "event",
          "label" => event_summary(event),
          "round" => event["round"],
          "strength" => min(number(event["target_count"]) / population, 1.0),
          "detail" => event["type"]
        }
      end)

    decision_drivers =
      Enum.map(pack.model_decisions, fn decision ->
        %{
          "ref" => decision["ref"],
          "kind" => "decision",
          "label" => decision["action_id"],
          "round" => decision["round"],
          "strength" => min(number(decision["affected_agents"]) / population, 1.0),
          "detail" => decision["short_rationale"],
          "source" => decision["source"]
        }
      end)

    action_drivers =
      pack.metrics
      |> Enum.filter(&(&1["kind"] == "action_frequency"))
      |> Enum.map(fn metric ->
        %{
          "ref" => metric["ref"],
          "kind" => "action",
          "label" => metric["id"],
          "strength" => number(metric["share_of_actions"]),
          "detail" => "recorded_action_share"
        }
      end)

    baseline =
      if comparison_pack,
        do: comparison_driver_strengths(comparison_pack),
        else: %{}

    (event_drivers ++ decision_drivers ++ action_drivers)
    |> Enum.sort_by(&{-&1["strength"], &1["ref"]})
    |> Enum.take(@max_drivers)
    |> Enum.map(fn driver ->
      driver
      |> maybe_comparison("baseline_strength", baseline[driver["ref"]])
      |> maybe_delta("strength_delta", driver["strength"], baseline[driver["ref"]])
    end)
  end

  defp comparison_driver_strengths(pack) do
    population = max(pack.usage["population_size"] || 1, 1)

    decisions =
      Map.new(pack.model_decisions, fn decision ->
        {decision["ref"], min(number(decision["affected_agents"]) / population, 1.0)}
      end)

    actions =
      pack.metrics
      |> Enum.filter(&(&1["kind"] == "action_frequency"))
      |> Map.new(&{&1["ref"], number(&1["share_of_actions"])})

    Map.merge(decisions, actions)
  end

  defp event_summary(%{
         "type" => "simulation.world_event",
         "payload" => %{"event_id" => event_id}
       }),
       do: "Scheduled event applied · #{humanize_identifier(event_id)}"

  defp event_summary(%{
         "type" => "simulation.transition",
         "payload" => %{"transition_id" => transition_id}
       }),
       do: "Transition applied · #{humanize_identifier(transition_id)}"

  defp event_summary(event), do: event["summary"] || event["type"] || "Recorded event"

  defp humanize_identifier(value),
    do: value |> to_string() |> String.replace("_", " ")

  defp comparison(_pack, nil), do: %{"status" => "none"}

  defp comparison(pack, comparison_pack) do
    current = pack.simulation_run_record
    baseline = comparison_pack.simulation_run_record
    compatibility = compatibility(current, baseline)

    %{
      "status" => "ready",
      "baseline" => run_summary(comparison_pack),
      "directly_comparable" => compatibility.differences == [],
      "differences" => compatibility.differences,
      "controlled_differences" => compatibility.controlled,
      "metric_deltas" => metric_deltas(pack, comparison_pack)
    }
  end

  defp compatibility(current, baseline) do
    checks = [
      {"population_model", current.population_model_id, baseline.population_model_id},
      {"simulation_script", current.simulation_script_id, baseline.simulation_script_id},
      {"execution_mode", current.mode, baseline.mode},
      {"model_route", current.model_route_plan_id, baseline.model_route_plan_id},
      {"budget", current.budget_plan_id, baseline.budget_plan_id}
    ]

    differences =
      checks
      |> Enum.flat_map(fn {field, current_value, baseline_value} ->
        if current_value == baseline_value,
          do: [],
          else: [difference(field, current_value, baseline_value)]
      end)

    controlled =
      [
        difference("seed", current.seed, baseline.seed),
        difference("replay_kind", current.replay_kind, baseline.replay_kind)
      ]
      |> Enum.reject(&(&1["current"] == &1["baseline"]))

    %{differences: differences, controlled: controlled}
  end

  defp difference(field, current, baseline),
    do: %{"field" => field, "current" => to_string(current), "baseline" => to_string(baseline)}

  defp metric_deltas(pack, comparison_pack) do
    baseline = Map.new(comparison_pack.metrics, &{&1["id"], &1})

    pack.metrics
    |> Enum.flat_map(fn metric ->
      with current when is_number(current) <- metric["final"],
           %{} = baseline_metric <- baseline[metric["id"]],
           baseline_value when is_number(baseline_value) <- baseline_metric["final"] do
        [
          %{
            "ref" => metric["ref"],
            "id" => metric["id"],
            "current" => current,
            "baseline" => baseline_value,
            "delta" => normalize_number(current - baseline_value),
            "unit" => metric["unit"]
          }
        ]
      else
        _other -> []
      end
    end)
    |> Enum.take(32)
  end

  defp final_aggregates(record_id) do
    result =
      RunSnapshot
      |> where([snapshot], snapshot.simulation_run_record_id == ^record_id)
      |> order_by([snapshot], desc: snapshot.round)
      |> limit(1)
      |> select([snapshot], %{
        "resources" =>
          fragment(
            """
            (SELECT COALESCE(
              jsonb_agg(
                jsonb_build_object(
                  'resource', stats.resource,
                  'minimum', stats.minimum,
                  'maximum', stats.maximum,
                  'mean', stats.mean
                ) ORDER BY stats.resource
              ), '[]'::jsonb)
            FROM (
              SELECT entry.key AS resource,
                     min((entry.value #>> '{}')::numeric)::double precision AS minimum,
                     max((entry.value #>> '{}')::numeric)::double precision AS maximum,
                     avg((entry.value #>> '{}')::numeric)::double precision AS mean
              FROM jsonb_array_elements(?->'agents') AS agent
              CROSS JOIN LATERAL jsonb_each(agent->'resources') AS entry
              GROUP BY entry.key
            ) AS stats)
            """,
            snapshot.payload
          ),
        "states" =>
          fragment(
            """
            (SELECT COALESCE(
              jsonb_agg(
                jsonb_build_object('key', stats.key, 'value', stats.value, 'count', stats.count)
                ORDER BY stats.key, stats.count DESC, stats.value
              ), '[]'::jsonb)
            FROM (
              SELECT entry.key AS key, entry.value #>> '{}' AS value, count(*)::integer AS count
              FROM jsonb_array_elements(?->'agents') AS agent
              CROSS JOIN LATERAL jsonb_each(agent->'state') AS entry
              WHERE entry.key IN ('phase', 'last_action')
              GROUP BY entry.key, entry.value
            ) AS stats)
            """,
            snapshot.payload
          ),
        "relationships" =>
          fragment(
            """
            (SELECT COALESCE(
              jsonb_agg(
                jsonb_build_object('type', stats.type, 'count', stats.count)
                ORDER BY stats.count DESC, stats.type
              ), '[]'::jsonb)
            FROM (
              SELECT relationship->>'type' AS type, count(*)::integer AS count
              FROM jsonb_array_elements(?->'relationships') AS relationship
              GROUP BY relationship->>'type'
            ) AS stats)
            """,
            snapshot.payload
          )
      })
      |> Repo.one()

    result || %{"resources" => [], "states" => [], "relationships" => []}
  end

  defp agent_history(record_id, agent_id) do
    RunSnapshot
    |> where([snapshot], snapshot.simulation_run_record_id == ^record_id)
    |> order_by([snapshot], asc: snapshot.round)
    |> limit(@max_history)
    |> select([snapshot], %{
      "round" => snapshot.round,
      "agent" =>
        fragment(
          """
          (SELECT item
           FROM jsonb_array_elements(?->'agents') AS item
           WHERE item->>'id' = ?
           LIMIT 1)
          """,
          snapshot.payload,
          ^agent_id
        )
    })
    |> Repo.all()
    |> Enum.reject(&is_nil(&1["agent"]))
  end

  defp agent_relationships(record_id, agent_id) do
    RunSnapshot
    |> where([snapshot], snapshot.simulation_run_record_id == ^record_id)
    |> order_by([snapshot], desc: snapshot.round)
    |> limit(1)
    |> select(
      [snapshot],
      fragment(
        """
        (SELECT COALESCE(jsonb_agg(selected.item ORDER BY selected.item->>'id'), '[]'::jsonb)
         FROM (
           SELECT item
           FROM jsonb_array_elements(?->'relationships') AS item
           WHERE item->>'source' = ? OR item->>'target' = ?
           ORDER BY item->>'id'
           LIMIT ?
         ) AS selected)
        """,
        snapshot.payload,
        ^agent_id,
        ^agent_id,
        ^@max_relationships
      )
    )
    |> Repo.one()
    |> Kernel.||([])
  end

  defp agent_decisions(record_id, agent_id) do
    RunDecisionAgent
    |> join(:inner, [mapping], decision in RunDecision,
      on: decision.id == mapping.simulation_run_decision_id
    )
    |> where(
      [mapping, decision],
      mapping.simulation_run_record_id == ^record_id and mapping.agent_id == ^agent_id
    )
    |> order_by([mapping, decision], asc: decision.sequence)
    |> limit(@max_decisions)
    |> select([mapping, decision], %{
      "reuse_kind" => mapping.reuse_kind,
      "round" => mapping.round,
      "decision_id" => decision.id,
      "action_id" => decision.action_id,
      "source" => decision.source,
      "affected_agent_count" => decision.affected_agent_count,
      "reason_codes" => decision.reason_codes,
      "short_rationale" => decision.short_rationale,
      "uncertainty" => decision.uncertainty,
      "fallback" => decision.fallback,
      "signature_context" => fragment("?->'signature_context'", decision.prompt_snapshot)
    })
    |> Repo.all()
  end

  defp representative(record, agent_id) do
    record.population_model.compile_summary
    |> Map.get("representatives", [])
    |> Enum.find(&(&1["agent_id"] == agent_id))
  end

  defp persona(nil, _locale), do: nil

  defp persona(representative, locale) do
    case PersonaRenderer.render(representative, if(locale == "ru", do: "ru", else: "en")) do
      {:ok, projection} ->
        %{
          "prose" => projection.prose,
          "generated_by" => projection.generated_by,
          "authoritative" => false
        }

      _error ->
        nil
    end
  end

  defp grounding(_record, nil), do: []

  defp grounding(record, representative) do
    ids = MapSet.new(representative["grounding"] || [])

    claims =
      Enum.map(record.context_pack.claims || [], fn claim ->
        %{
          "id" => claim["id"],
          "kind" => "claim",
          "statement" => claim["statement"],
          "grounding_class" => claim["grounding_class"],
          "confidence" => claim["confidence"]
        }
      end)

    assumptions =
      Enum.map(record.context_pack.assumptions || [], fn assumption ->
        %{
          "id" => assumption["id"],
          "kind" => "assumption",
          "statement" => assumption["statement"]
        }
      end)

    (claims ++ assumptions)
    |> Enum.filter(&MapSet.member?(ids, &1["id"]))
    |> Enum.take(@max_grounding)
  end

  defp bounded_agent(agent) do
    agent
    |> Map.take([
      "id",
      "type",
      "archetype",
      "attributes",
      "state",
      "resources",
      "goals",
      "constraints",
      "policy_id",
      "imported"
    ])
    |> Map.update("attributes", %{}, &bounded_map/1)
    |> Map.update("state", %{}, &bounded_map/1)
    |> Map.update("resources", %{}, &bounded_map/1)
    |> Map.update("goals", [], &Enum.take(List.wrap(&1), 12))
    |> Map.update("constraints", [], &Enum.take(List.wrap(&1), 12))
  end

  defp history_row(%{"round" => round, "agent" => agent}) do
    %{
      "round" => round,
      "state" => bounded_map(agent["state"]),
      "resources" => bounded_map(agent["resources"]),
      "action" => get_in(agent, ["state", "last_action"])
    }
  end

  defp relationship(item, agent_id) do
    other = if item["source"] == agent_id, do: item["target"], else: item["source"]

    %{
      "id" => item["id"],
      "type" => item["type"],
      "other_agent_id" => other,
      "direction" => relationship_direction(item, agent_id),
      "weight" => item["weight"],
      "state" => bounded_map(item["state"])
    }
  end

  defp relationship_direction(%{"directed" => false}, _agent_id), do: "undirected"
  defp relationship_direction(%{"source" => agent_id}, agent_id), do: "outgoing"
  defp relationship_direction(_item, _agent_id), do: "incoming"

  defp decision(item) do
    %{
      "ref" => "decision:#{item["decision_id"]}",
      "round" => item["round"],
      "action_id" => item["action_id"],
      "source" => item["source"],
      "reuse_kind" => item["reuse_kind"],
      "affected_agent_count" => item["affected_agent_count"],
      "reason_codes" => Enum.take(item["reason_codes"] || [], 12),
      "short_rationale" => item["short_rationale"],
      "uncertainty" => decimal_float(item["uncertainty"]),
      "fallback" => item["fallback"],
      "perceived_context" =>
        bounded_map(
          Map.take(item["signature_context"] || %{}, [
            "recent_event_types",
            "relationship_class",
            "state",
            "resources",
            "world"
          ])
        )
    }
  end

  defp stable_position(value) do
    digest = :crypto.hash(:sha256, value)
    <<x::unsigned-integer-size(32), y::unsigned-integer-size(32), _rest::binary>> = digest

    %{
      "x" => normalize_number(0.08 + x / 4_294_967_295 * 0.84),
      "y" => normalize_number(0.1 + y / 4_294_967_295 * 0.8)
    }
  end

  defp maybe_comparison(map, _key, nil), do: map
  defp maybe_comparison(map, key, value), do: Map.put(map, key, value)

  defp maybe_delta(map, _key, _current, nil), do: map

  defp maybe_delta(map, key, current, baseline),
    do: Map.put(map, key, normalize_number(number(current) - number(baseline)))

  defp bounded_map(value) when is_map(value) do
    value |> Enum.sort_by(&elem(&1, 0)) |> Enum.take(20) |> Map.new()
  end

  defp bounded_map(_value), do: %{}

  defp number(value) when is_integer(value) or is_float(value), do: value * 1.0
  defp number(%D{} = value), do: D.to_float(value)

  defp number(value) when is_binary(value) do
    case Float.parse(value) do
      {parsed, _rest} -> parsed
      :error -> 0.0
    end
  end

  defp number(_value), do: 0.0

  defp decimal_float(nil), do: nil
  defp decimal_float(value), do: number(value)

  defp normalize_number(value) when is_float(value), do: Float.round(value, 6)
  defp normalize_number(value), do: value
end
