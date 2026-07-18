defmodule HydraAgent.SimLab.Simulator do
  @moduledoc """
  A cheap deterministic simulation for the Observatory prototype.

  It aggregates cohorts at each tick. The UI therefore never receives a
  per-agent DOM representation or needs an LLM call for each synthetic agent.
  """

  @actions ["adopt", "resist", "ignore", "share"]

  def run(%{
        personas: personas,
        patterns: patterns,
        events: events,
        agent_count: agent_count,
        seed: seed
      }) do
    snapshots =
      events
      |> Enum.with_index(1)
      |> Enum.map(fn {event, tick} ->
        snapshot(personas, patterns, event, Enum.take(events, tick), tick, agent_count, seed)
      end)

    %{
      snapshots: snapshots,
      decision_counts: decision_counts(agent_count, length(events))
    }
  end

  defp snapshot(personas, patterns, event, event_history, tick, agent_count, seed) do
    action_effects = cumulative_action_effects(event_history)

    clusters =
      personas
      |> apportion(agent_count, &Map.get(&1, :weight, 0.0))
      |> Enum.flat_map(fn {persona, persona_count} ->
        persona
        |> patterns_for_persona(patterns)
        |> cohort_counts(persona_count)
        |> Enum.with_index()
        |> Enum.flat_map(fn {{pattern, cohort_count}, index} ->
          pattern_clusters(
            persona,
            pattern,
            cohort_count,
            index,
            action_effects,
            tick,
            seed
          )
        end)
      end)

    %{
      tick: tick,
      day: event.day,
      label: "Day #{event.day}",
      event: event.title,
      clusters: clusters,
      metrics: metrics(clusters, agent_count),
      cost: %{estimated_usd: 0.0, actual_usd: 0.0}
    }
  end

  defp pattern_clusters(
         persona,
         pattern,
         cohort_count,
         index,
         action_effects,
         tick,
         seed
       ) do
    {action, probability} =
      case Map.get(pattern, :action) do
        action when action in @actions -> {action, effective_probability(pattern, action_effects)}
        _unknown_action -> {"ignore", 1.0}
      end

    confidence = min(persona.confidence, pattern.confidence || persona.confidence)
    cluster_key = "#{persona.id}:#{index}:#{pattern.name}"
    action_count = round(cohort_count * probability)
    alternative_count = cohort_count - action_count

    []
    |> maybe_add_cluster(
      action_count,
      persona,
      pattern,
      cluster_key,
      action,
      probability,
      confidence,
      tick,
      seed,
      false
    )
    |> maybe_add_cluster(
      alternative_count,
      persona,
      pattern,
      cluster_key,
      alternative_action(action),
      1 - probability,
      confidence,
      tick,
      seed,
      true
    )
  end

  # An ignore rule describes the probability of waiting. Its complement is
  # adoption, while every other action's complement remains waiting.
  defp alternative_action("ignore"), do: "adopt"
  defp alternative_action(_action), do: "ignore"

  defp maybe_add_cluster(
         clusters,
         count,
         persona,
         pattern,
         cluster_key,
         action,
         probability,
         confidence,
         tick,
         seed,
         alternative?
       )
       when count > 0 do
    clusters ++
      [
        cluster(
          persona,
          pattern,
          cluster_key,
          action,
          count,
          probability,
          confidence,
          tick,
          seed,
          alternative?
        )
      ]
  end

  defp maybe_add_cluster(
         clusters,
         _count,
         _persona,
         _pattern,
         _cluster_key,
         _action,
         _probability,
         _confidence,
         _tick,
         _seed,
         _alternative?
       ),
       do: clusters

  defp cluster(
         persona,
         pattern,
         cluster_key,
         action,
         count,
         probability,
         confidence,
         tick,
         seed,
         alternative?
       ) do
    id = "#{cluster_key}-#{action}"

    %{
      id: id,
      persona: persona.name,
      persona_id: persona.id,
      action: action,
      count: count,
      confidence: confidence,
      uncertainty: Float.round(1 - confidence, 2),
      x: x_for(cluster_key, action, tick, seed),
      y: y_for(cluster_key, action, tick, seed),
      color: persona.color,
      dominant_pattern: pattern.name,
      pattern_probability: Float.round(probability, 4),
      representative_agent_id: representative_agent_id(id),
      condition: Map.get(pattern, :condition),
      interpretation: Map.get(pattern, :interpretation),
      state_updates: Map.get(pattern, :state_updates, %{}),
      alternative: alternative?
    }
  end

  defp effective_probability(pattern, action_effects) do
    base = numeric(Map.get(pattern, :probability), 0.0)

    scenario_delta =
      pattern
      |> Map.get(:executable_rule, %{})
      |> Map.get("scenario_probability_delta", 0.0)
      |> numeric(0.0)

    event_delta = Map.get(action_effects, pattern.action, 0.0)

    base
    |> Kernel.+(scenario_delta + event_delta)
    |> max(0.0)
    |> min(1.0)
  end

  defp cumulative_action_effects(events) do
    Enum.reduce(events, Map.new(@actions, &{&1, 0.0}), fn event, totals ->
      Map.new(totals, fn {action, current} ->
        effect = event |> Map.get(:action_effects, %{}) |> Map.get(action, 0.0) |> numeric(0.0)
        {action, max(-0.5, min(0.5, current + effect))}
      end)
    end)
  end

  defp numeric(value, _default) when is_number(value), do: value * 1.0
  defp numeric(_value, default), do: default

  defp decision_counts(agent_count, event_count) do
    %{
      pattern: agent_count * event_count,
      small_model: 0,
      large_model: 0
    }
  end

  defp patterns_for_persona(persona, patterns) do
    case Enum.filter(patterns, &(&1.persona == persona.id)) do
      [] ->
        [
          %{
            persona: persona.id,
            name: "No action rule recorded",
            action: "ignore",
            probability: 1.0,
            confidence: min(persona.confidence, 0.25),
            share: 1.0
          }
        ]

      matching_patterns ->
        matching_patterns
    end
  end

  defp cohort_counts(patterns, total), do: apportion(patterns, total, &Map.get(&1, :share, 0.0))

  # Largest-remainder apportionment keeps every population integer, preserves
  # the requested total, and resolves equal remainders by stable input order.
  defp apportion([], _total, _weight), do: []

  defp apportion(items, total, weight) when is_integer(total) and total >= 0 do
    weights = Enum.map(items, &(weight.(&1) |> numeric(0.0) |> max(0.0)))

    weights =
      if Enum.sum(weights) > 0.0,
        do: weights,
        else: List.duplicate(1.0, length(items))

    weight_total = Enum.sum(weights)

    allocations =
      items
      |> Enum.zip(weights)
      |> Enum.with_index()
      |> Enum.map(fn {{item, item_weight}, index} ->
        exact = total * item_weight / weight_total
        count = floor(exact)
        %{item: item, index: index, count: count, remainder: exact - count}
      end)

    extra = total - Enum.sum_by(allocations, & &1.count)

    bonus_indices =
      allocations
      |> Enum.sort_by(&{-&1.remainder, &1.index})
      |> Enum.take(extra)
      |> Enum.map(& &1.index)
      |> MapSet.new()

    Enum.map(allocations, fn allocation ->
      bonus = if MapSet.member?(bonus_indices, allocation.index), do: 1, else: 0
      {allocation.item, allocation.count + bonus}
    end)
  end

  defp metrics(_clusters, total) when total <= 0, do: Map.new(@actions, &{&1, 0.0})

  defp metrics(clusters, total) do
    counts =
      Enum.reduce(clusters, %{}, fn cluster, acc ->
        Map.update(acc, cluster.action, cluster.count, &(&1 + cluster.count))
      end)

    Map.new(@actions, fn action ->
      {action, Map.get(counts, action, 0) / total}
    end)
  end

  defp x_for(persona, action, tick, seed), do: coordinate(persona <> action, tick, seed, 0.21)
  defp y_for(persona, action, tick, seed), do: coordinate(action <> persona, tick, seed, 0.37)

  defp coordinate(value, tick, seed, offset) do
    hash = :erlang.phash2({value, tick, seed}, 10_000) / 10_000
    Float.round(0.15 + rem(tick, 3) * 0.04 + hash * 0.64 + offset * 0.04, 3)
  end

  # This is a stable cohort handle, not a persisted individual. It allows the
  # Observatory to request one deterministic explanatory trace without ever
  # shipping a raw population ledger to the client.
  defp representative_agent_id(cluster_key) do
    "cohort_" <> Base.url_encode64(:erlang.term_to_binary(cluster_key), padding: false)
  end
end
