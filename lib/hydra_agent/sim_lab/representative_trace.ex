defmodule HydraAgent.SimLab.RepresentativeTrace do
  @moduledoc """
  Builds an inspectable trace for one deterministic representative cohort.

  The trace is derived on demand from persisted aggregate snapshots. It is
  deliberately not a stored person, a raw-agent ledger, or evidence of an LLM
  decision. The response makes that boundary explicit for UI and API clients.
  """

  def build(run, snapshots, agent_id, patterns) when is_binary(agent_id) do
    case cohort_timeline(snapshots, agent_id) do
      [] ->
        {:error, :representative_agent_not_in_run}

      [first | _] = timeline ->
        pattern = matching_pattern(patterns, value(first.cluster, :dominant_pattern))

        {:ok,
         %{
           agent_id: agent_id,
           detail_level: "representative_cohort_trace",
           representation: "deterministic_cohort_sample",
           persona: value(first.cluster, :persona),
           persona_id: value(first.cluster, :persona_id),
           parameters: parameters(run.seed, agent_id),
           parameters_disclosure:
             "Illustrative deterministic variation for explanation only. It does not represent a stored individual or alter the aggregate result.",
           sampled_from: %{
             cluster_id: value(first.cluster, :id),
             cohort_count: value(first.cluster, :count),
             description:
               "One deterministic trace representing the selected aggregate cohort across this replay."
           },
           activated_pattern: pattern_summary(pattern, first.cluster),
           evidence_refs: refs(pattern, :evidence_refs),
           assumption_refs: refs(pattern, :assumption_refs),
           llm_fallback_used: false,
           trace: Enum.map(timeline, &trace_step(&1, run))
         }}
    end
  end

  defp cohort_timeline(snapshots, agent_id) do
    snapshots
    |> Enum.flat_map(fn snapshot ->
      snapshot
      |> groups()
      |> Enum.find(&(value(&1, :representative_agent_id) == agent_id))
      |> case do
        nil -> []
        cluster -> [%{snapshot: snapshot, cluster: cluster}]
      end
    end)
  end

  defp trace_step(%{snapshot: snapshot, cluster: cluster}, run) do
    action = value(cluster, :action) || "ignore"
    probability = probability(cluster)

    %{
      tick: snapshot.tick,
      label: snapshot.label,
      event: event_for(run, snapshot),
      matched_patterns: [value(cluster, :dominant_pattern)],
      decision: action,
      probability: probability,
      confidence: value(cluster, :confidence),
      state_delta: %{"#{action}_tendency" => probability},
      llm_fallback_used: false
    }
  end

  defp groups(snapshot), do: value(snapshot.clusters || %{}, :groups) || []

  defp matching_pattern(patterns, dominant_pattern) do
    name = normalize_pattern_name(dominant_pattern)
    Enum.find(patterns, &(normalize_pattern_name(value(&1, :name)) == name))
  end

  defp pattern_summary(nil, cluster) do
    %{
      name: value(cluster, :dominant_pattern),
      grounding_level: "aggregate_replay",
      confidence: value(cluster, :confidence)
    }
  end

  defp pattern_summary(pattern, _cluster) do
    %{
      id: value(pattern, :id),
      name: value(pattern, :name),
      grounding_level: value(pattern, :grounding_level) || "aggregate_replay",
      confidence: value(pattern, :confidence),
      condition: value(pattern, :condition),
      interpretation: value(pattern, :interpretation)
    }
  end

  defp refs(nil, _field), do: []
  defp refs(pattern, field), do: value(pattern, field) || []

  defp event_for(run, snapshot) do
    events =
      case value(value(run, :input_snapshot), :events) do
        events when is_list(events) and events != [] -> events
        _ -> value(value(run, :scenario), :events) || []
      end

    events
    |> Enum.at(max(snapshot.tick - 1, 0), %{})
    |> value(:title)
    |> Kernel.||(snapshot.label)
  end

  defp probability(cluster) do
    cluster
    |> value(:pattern_probability)
    |> case do
      value when is_number(value) -> Float.round(value, 4)
      _ -> Float.round(value(cluster, :confidence) || 0.0, 4)
    end
  end

  defp parameters(seed, agent_id) do
    %{
      change_readiness: seeded_parameter(seed, agent_id, 1),
      trust_in_change: seeded_parameter(seed, agent_id, 2),
      control_sensitivity: seeded_parameter(seed, agent_id, 3)
    }
  end

  defp seeded_parameter(seed, agent_id, dimension) do
    seed = if is_integer(seed), do: seed, else: 0
    Float.round(0.2 + :erlang.phash2({seed, agent_id, dimension}, 600) / 1_000, 2)
  end

  defp normalize_pattern_name(name) when is_binary(name),
    do: String.replace(name, ~r/ · (control-first|manager-recognition) hypothesis$/, "")

  defp normalize_pattern_name(_name), do: ""

  defp value(map, key) when is_map(map), do: Map.get(map, key) || Map.get(map, to_string(key))
  defp value(_map, _key), do: nil
end
