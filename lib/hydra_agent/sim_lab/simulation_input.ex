defmodule HydraAgent.SimLab.SimulationInput do
  @moduledoc """
  Compiles durable study records into the aggregate simulator's compact input.

  Missing action rules never become invisible certainty: they are represented
  as a low-confidence waiting cohort, and unallocated population is carried as
  an explicit unmodelled remainder.
  """

  alias HydraAgent.SimLab.Costing

  @palette ["#66d9b5", "#ef856b", "#d5ba6b", "#7d9cf5", "#c59ae8", "#84c5dd"]
  @action_atoms %{"adopt" => :adopt, "resist" => :resist, "ignore" => :ignore, "share" => :share}

  def build(personas, patterns, scenario, opts \\ %{}) when is_list(personas) do
    opts = Map.new(opts)

    case personas do
      [] -> {:error, :no_personas}
      _ -> {:ok, compile(personas, patterns, scenario, opts)}
    end
  end

  defp compile(personas, patterns, scenario, opts) do
    mode = Map.get(opts, :mode, "small")
    cost = Costing.estimate(mode)

    compiled_personas =
      Enum.with_index(personas, fn persona, index -> compile_persona({persona, index}) end)

    covered_weight = Enum.sum_by(compiled_personas, & &1.weight)
    remainder = max(1.0 - covered_weight, 0.0)

    personas =
      if remainder > 0.001,
        do: compiled_personas ++ [remainder_persona(remainder)],
        else: compiled_personas

    %{
      input: %{
        personas: personas,
        patterns: compile_patterns(personas, patterns, scenario_modifier(scenario)),
        events: compile_events(scenario.events, scenario.name),
        seed: Map.get(opts, :seed, :erlang.phash2({scenario.id, scenario.updated_at}, 1_000_000)),
        agent_count: cost.agents
      },
      cost: cost,
      coverage: %{
        modeled_population: Float.round(min(covered_weight, 1.0), 2),
        unmodelled_population: Float.round(remainder, 2),
        action_rules: length(patterns),
        grounded_rule_ratio: grounded_rule_ratio(patterns),
        mechanism_event_ratio: mechanism_event_ratio(scenario.events)
      }
    }
  end

  defp compile_persona({persona, index}) do
    %{
      id: to_string(persona.id),
      name: persona.name,
      weight: persona.distribution_weight,
      color: Enum.at(@palette, rem(index, length(@palette))),
      confidence: persona.confidence || 0.5
    }
  end

  defp remainder_persona(weight) do
    %{
      id: "unmodelled-remainder",
      name: "Unmodelled remainder",
      weight: weight,
      color: "#8a9891",
      confidence: 0.15
    }
  end

  defp compile_patterns(personas, patterns, modifier) do
    patterns_by_persona =
      Enum.group_by(patterns, fn pattern -> pattern.persona_ids |> List.first() |> to_string() end)

    Enum.flat_map(personas, fn persona ->
      case Map.get(patterns_by_persona, persona.id) do
        nil ->
          [fallback_pattern(persona)]

        matching_patterns ->
          matching_patterns
          |> Enum.map(&compiled_pattern(&1, persona))
          |> Enum.map(&apply_scenario_modifier(&1, modifier))
          |> assign_pattern_shares()
      end
    end)
  end

  defp fallback_pattern(persona) do
    %{
      persona: persona.id,
      name: "No action rule recorded",
      action: "ignore",
      probability: 1.0,
      confidence: min(persona.confidence, 0.25),
      grounding_level: "assumption",
      evidence_refs: [],
      assumption_refs: ["missing_action_rule"],
      share: 1.0
    }
  end

  defp compiled_pattern(pattern, persona) do
    %{
      persona: persona.id,
      id: pattern |> Map.get(:id, Map.get(pattern, "id", pattern.name)) |> to_string(),
      version: Map.get(pattern, :version, Map.get(pattern, "version")),
      name: pattern.name,
      action: pattern.likely_action,
      probability: pattern.base_probability,
      confidence: pattern.confidence || 0.5,
      condition: Map.get(pattern, :condition),
      interpretation: Map.get(pattern, :interpretation),
      motivation: Map.get(pattern, :motivation),
      blockers: Map.get(pattern, :blockers, []),
      amplifiers: Map.get(pattern, :amplifiers, []),
      grounding_level: Map.get(pattern, :grounding_level),
      evidence_refs: Map.get(pattern, :evidence_refs, []) || [],
      assumption_refs: Map.get(pattern, :assumption_refs, []) || [],
      state_updates: Map.get(pattern, :state_updates, %{}),
      executable_rule: Map.get(pattern, :executable_rule, %{})
    }
  end

  defp assign_pattern_shares(patterns) do
    declared_shares = Enum.map(patterns, &declared_population_share/1)
    total_declared_share = Enum.sum(declared_shares)

    case {patterns, total_declared_share} do
      {[], _} ->
        []

      {_patterns, total} when total > 0 ->
        patterns
        |> Enum.zip(declared_shares)
        |> Enum.map(fn {pattern, declared_share} ->
          Map.put(
            pattern,
            :share,
            Float.round(declared_share / total, 6)
          )
        end)

      {patterns, _} ->
        equal_share = Float.round(1 / length(patterns), 6)
        Enum.map(patterns, &Map.put(&1, :share, equal_share))
    end
  end

  defp positive_probability(value) when is_number(value), do: max(value, 0.0)
  defp positive_probability(_value), do: 0.0

  defp declared_population_share(pattern) do
    pattern.executable_rule
    |> Map.get("population_share", Map.get(pattern.executable_rule, :population_share))
    |> positive_probability()
  end

  defp apply_scenario_modifier(pattern, "control_first_opt_in") do
    adjustment =
      if pattern.action == "resist",
        do: -0.2,
        else: if(pattern.action == "adopt", do: 0.1, else: 0.0)

    pattern
    |> put_in([:executable_rule, "scenario_probability_delta"], adjustment)
    |> Map.update!(:name, &"#{&1} · control-first hypothesis")
    |> Map.update!(:confidence, &min(&1, 0.55))
  end

  defp apply_scenario_modifier(pattern, "manager_recognition") do
    adjustment =
      if pattern.action == "ignore",
        do: -0.2,
        else: if(pattern.action == "adopt", do: 0.12, else: 0.0)

    pattern
    |> put_in([:executable_rule, "scenario_probability_delta"], adjustment)
    |> Map.update!(:name, &"#{&1} · manager-recognition hypothesis")
    |> Map.update!(:confidence, &min(&1, 0.55))
  end

  defp apply_scenario_modifier(pattern, _modifier), do: pattern

  defp scenario_modifier(scenario) do
    Map.get(scenario.metadata || %{}, "simulation_modifier")
  end

  defp compile_events([], scenario_name),
    do: [%{day: 1, title: scenario_name, impact: "Scenario begins."}]

  defp compile_events(events, _scenario_name) do
    events
    |> Enum.map(fn event ->
      %{
        day: parse_day(event["day"] || event[:day]),
        title: event["title"] || event[:title] || "Scenario event",
        impact: event["impact"] || event[:impact] || "Behavior may shift.",
        action_effects:
          normalize_action_effects(event["action_effects"] || event[:action_effects])
      }
    end)
    |> Enum.sort_by(& &1.day)
  end

  defp parse_day(day) when is_integer(day), do: max(day, 1)

  defp parse_day(day) when is_binary(day) do
    case Integer.parse(day) do
      {value, ""} -> max(value, 1)
      _ -> 1
    end
  end

  defp parse_day(_), do: 1

  defp normalize_action_effects(effects) when is_map(effects) do
    Map.new(~w(adopt resist ignore share), fn action ->
      value = Map.get(effects, action, Map.get(effects, Map.fetch!(@action_atoms, action), 0.0))
      {action, normalize_delta(value)}
    end)
  end

  defp normalize_action_effects(_effects),
    do: %{"adopt" => 0.0, "resist" => 0.0, "ignore" => 0.0, "share" => 0.0}

  defp normalize_delta(value) when is_number(value), do: value |> max(-0.5) |> min(0.5)

  defp normalize_delta(value) when is_binary(value) do
    case Float.parse(value) do
      {number, ""} -> normalize_delta(number)
      _ -> 0.0
    end
  end

  defp normalize_delta(_value), do: 0.0

  defp grounded_rule_ratio([]), do: 0.0

  defp grounded_rule_ratio(patterns) do
    grounded =
      Enum.count(patterns, fn pattern ->
        evidence_refs = Map.get(pattern, :evidence_refs, [])
        grounding_level = Map.get(pattern, :grounding_level)

        evidence_refs != [] or
          grounding_level in ["direct_user_data", "external_research", "mixed"]
      end)

    Float.round(grounded / length(patterns), 2)
  end

  defp mechanism_event_ratio([]), do: 0.0

  defp mechanism_event_ratio(events) do
    explicit =
      Enum.count(events, fn event ->
        effects = event["action_effects"] || event[:action_effects] || %{}
        Enum.any?(effects, fn {_action, value} -> normalize_delta(value) != 0.0 end)
      end)

    Float.round(explicit / length(events), 2)
  end
end
