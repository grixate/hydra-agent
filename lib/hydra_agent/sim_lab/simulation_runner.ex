defmodule HydraAgent.SimLab.SimulationRunner do
  @moduledoc """
  Converts deterministic aggregate simulation output into durable run records.

  It stores cohort summaries rather than individual synthetic agents. This is
  the boundary that keeps replay payloads small and the Observatory scalable.
  """

  alias HydraAgent.SimLab.{Forecast, Simulator}

  def prepare(input, study, opts \\ %{}) do
    opts = Map.new(opts)
    result = Simulator.run(input)
    total_ticks = length(result.snapshots)

    snapshots =
      Enum.map(result.snapshots, &snapshot_attrs(&1, result.decision_counts, total_ticks))

    outcome_events = Enum.flat_map(result.snapshots, &outcome_event_attrs/1)

    last_snapshot = List.last(result.snapshots)
    confidence = Map.get(opts, :confidence, 0.6)
    input_snapshot = snapshot_input(input)

    %{
      run: %{
        mode: Map.get(opts, :mode, "small"),
        agent_count: input.agent_count,
        rounds: length(result.snapshots),
        seed: input.seed,
        status: "completed",
        budget_cap_usd: Map.get(opts, :budget_cap_usd),
        actual_cost_usd: last_snapshot.cost.actual_usd,
        decision_counts: stringify_keys(result.decision_counts),
        aggregate_metrics: stringify_keys(last_snapshot.metrics),
        input_snapshot: input_snapshot,
        input_fingerprint: input_fingerprint(input_snapshot),
        execution_options: execution_options(opts, confidence),
        confidence: confidence,
        started_at: DateTime.utc_now(),
        completed_at: DateTime.utc_now()
      },
      snapshots: snapshots,
      outcome_events: outcome_events,
      forecast: forecast_attrs(result, study, opts, confidence)
    }
  end

  defp snapshot_attrs(snapshot, decision_counts, total_ticks) do
    %{
      tick: snapshot.tick,
      label: snapshot.label,
      clusters: %{"groups" => snapshot.clusters},
      metrics: stringify_keys(snapshot.metrics),
      decision_counts: cumulative_counts(decision_counts, snapshot.tick, total_ticks),
      cost: stringify_keys(snapshot.cost),
      insight_refs: ["event:#{snapshot.event}"]
    }
  end

  defp cumulative_counts(decision_counts, tick, total_ticks) do
    decision_counts
    |> Map.new(fn {kind, count} -> {to_string(kind), round(count * tick / total_ticks)} end)
  end

  defp outcome_event_attrs(snapshot) do
    Enum.map(snapshot.clusters, fn cluster ->
      action = cluster.action
      probability = cluster.pattern_probability || cluster.confidence || 0.0

      %{
        tick: snapshot.tick,
        persona_id: to_string(cluster.persona_id),
        action_pattern: cluster.dominant_pattern,
        action: action,
        probability: probability,
        confidence: cluster.confidence,
        state_delta:
          Map.merge(cluster.state_updates || %{}, %{"#{action}_tendency" => probability}),
        metadata: %{
          "aggregate_count" => cluster.count,
          "cluster_id" => cluster.id,
          "representative_agent_id" => cluster.representative_agent_id,
          "llm_fallback_used" => false
        }
      }
    end)
  end

  defp forecast_attrs(result, study, opts, confidence) do
    report =
      Forecast.build(result, study,
        assumptions: Map.get(opts, :assumptions, []),
        confidence: confidence,
        evidence_map: Map.get(opts, :evidence_map),
        coverage: Map.get(opts, :coverage, %{})
      )

    report
    |> Map.update!(:outcome_probabilities, &stringify_keys/1)
    |> Map.update!(:evidence_map, &stringify_keys/1)
    |> Map.update!(:assumptions, &normalize_assumptions/1)
    |> Map.update!(:uncertainty, &stringify_keys/1)
  end

  defp normalize_assumptions(assumptions) do
    Enum.map(assumptions, fn
      assumption when is_binary(assumption) -> %{"statement" => assumption}
      assumption when is_map(assumption) -> stringify_keys(assumption)
      assumption -> %{"statement" => inspect(assumption)}
    end)
  end

  defp stringify_keys(map) do
    Map.new(map, fn {key, value} -> {to_string(key), value} end)
  end

  # The compiled simulation input contains only behavioral model parameters,
  # events, seed, and population size. It deliberately excludes source text,
  # raw evidence, and external provider payloads.
  def snapshot_input(input), do: json_value(input)

  def input_fingerprint(input_snapshot) do
    input_snapshot
    |> :erlang.term_to_binary([:deterministic])
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  @doc false
  def restore_input(snapshot) when is_map(snapshot) do
    %{
      personas: Enum.map(snapshot["personas"] || [], &restore_persona/1),
      patterns: Enum.map(snapshot["patterns"] || [], &restore_pattern/1),
      events: Enum.map(snapshot["events"] || [], &restore_event/1),
      agent_count: snapshot["agent_count"],
      seed: snapshot["seed"]
    }
  end

  @doc false
  def execution_options(opts, confidence) do
    %{
      "mode" => Map.get(opts, :mode, "small"),
      "confidence" => confidence,
      "budget_cap_usd" => Map.get(opts, :budget_cap_usd),
      "assumptions" => normalize_assumptions(Map.get(opts, :assumptions, [])),
      "evidence_map" => json_value(Map.get(opts, :evidence_map, %{})),
      "coverage" => json_value(Map.get(opts, :coverage, %{}))
    }
  end

  defp json_value(value) when is_map(value) do
    Map.new(value, fn {key, nested_value} -> {to_string(key), json_value(nested_value)} end)
  end

  defp json_value(value) when is_list(value), do: Enum.map(value, &json_value/1)
  defp json_value(value), do: value

  defp restore_persona(persona) do
    %{
      id: persona["id"],
      name: persona["name"],
      weight: persona["weight"],
      color: persona["color"],
      confidence: persona["confidence"]
    }
  end

  defp restore_pattern(pattern) do
    %{
      id: pattern["id"],
      version: pattern["version"],
      persona: pattern["persona"],
      name: pattern["name"],
      action: pattern["action"],
      probability: pattern["probability"],
      confidence: pattern["confidence"],
      share: pattern["share"],
      condition: pattern["condition"],
      interpretation: pattern["interpretation"],
      motivation: pattern["motivation"],
      blockers: pattern["blockers"] || [],
      amplifiers: pattern["amplifiers"] || [],
      grounding_level: pattern["grounding_level"],
      evidence_refs: pattern["evidence_refs"] || [],
      assumption_refs: pattern["assumption_refs"] || [],
      state_updates: pattern["state_updates"] || %{},
      executable_rule: pattern["executable_rule"] || %{}
    }
  end

  defp restore_event(event) do
    %{
      day: event["day"],
      title: event["title"],
      impact: event["impact"],
      action_effects: event["action_effects"] || %{}
    }
  end
end
