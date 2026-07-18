defmodule HydraAgent.SimLab.Forecast do
  @moduledoc """
  Converts aggregate snapshots into an evidence-linked directional forecast.

  Report language is derived from the compiled behavior model. The forecaster
  never inserts domain-specific drivers that were not present in the run.
  """

  @actions ~w(adopt resist ignore share)
  @action_atoms %{"adopt" => :adopt, "resist" => :resist, "ignore" => :ignore, "share" => :share}

  def build(%{snapshots: snapshots}, study, opts \\ %{}) when snapshots != [] do
    opts = Map.new(opts)
    last_snapshot = List.last(snapshots)
    metrics = last_snapshot.metrics
    assumptions = Map.get(opts, :assumptions, [])
    confidence = Map.get(opts, :confidence) || study_confidence(study)
    evidence_map = evidence_map(Map.get(opts, :evidence_map), assumptions)
    coverage = normalize_coverage(Map.get(opts, :coverage, %{}))
    behavior_drivers = behavior_drivers(last_snapshot.clusters, "adopt")
    resistance_drivers = behavior_drivers(last_snapshot.clusters, "resist")
    recommendations = validation_recommendations(last_snapshot.clusters, assumptions, coverage)

    %{
      title: study.question,
      executive_summary: summary(metrics, confidence, last_snapshot),
      outcome_probabilities: Map.new(@actions, &{&1, metric(metrics, &1)}),
      segment_reactions: segment_reactions(last_snapshot.clusters),
      behavior_drivers: behavior_drivers,
      resistance_drivers: resistance_drivers,
      evidence_map: evidence_map,
      assumptions: assumptions,
      uncertainty: %{
        confidence: confidence,
        modeled_population: coverage["modeled_population"],
        unmodelled_population: coverage["unmodelled_population"],
        evaluated_tick: last_snapshot.tick,
        evaluated_label: last_snapshot.label,
        note: uncertainty_note(confidence, coverage, last_snapshot)
      },
      validation_recommendations: recommendations,
      markdown_body:
        markdown(
          study,
          metrics,
          confidence,
          last_snapshot,
          assumptions,
          evidence_map,
          coverage,
          behavior_drivers,
          resistance_drivers,
          recommendations
        )
    }
  end

  defp summary(metrics, confidence, snapshot) do
    ordered =
      @actions
      |> Enum.map(&{&1, metric(metrics, &1)})
      |> Enum.sort_by(&elem(&1, 1), :desc)

    [{primary_action, primary_value}, {secondary_action, secondary_value} | _] = ordered

    "At #{snapshot.label}, the modeled population is directionally led by #{action_label(primary_action)} (#{percentage(primary_value)}), followed by #{action_label(secondary_action)} (#{percentage(secondary_value)}), at #{percentage(confidence)} confidence."
  end

  defp segment_reactions(clusters) do
    clusters
    |> Enum.group_by(& &1.persona)
    |> Enum.map(fn {persona, persona_clusters} ->
      dominant = Enum.max_by(persona_clusters, & &1.count)

      %{
        persona: persona,
        likely_action: dominant.action,
        confidence: dominant.confidence,
        dominant_pattern: dominant.dominant_pattern,
        modeled_count: Enum.sum_by(persona_clusters, & &1.count)
      }
    end)
    |> Enum.sort_by(& &1.modeled_count, :desc)
  end

  defp behavior_drivers(clusters, action) do
    clusters
    |> Enum.filter(&(&1.action == action and not &1.alternative))
    |> Enum.group_by(&{&1.dominant_pattern, &1.persona})
    |> Enum.map(fn {{pattern, persona}, matching} ->
      %{
        driver: pattern,
        impact: "Associated with #{action_label(action)} among #{persona}.",
        modeled_count: Enum.sum_by(matching, & &1.count),
        confidence: matching |> Enum.map(& &1.confidence) |> average()
      }
    end)
    |> Enum.sort_by(& &1.modeled_count, :desc)
    |> Enum.take(4)
  end

  defp validation_recommendations(clusters, assumptions, coverage) do
    uncertainty_checks =
      clusters
      |> Enum.reject(& &1.alternative)
      |> Enum.sort_by(& &1.confidence)
      |> Enum.uniq_by(&{&1.persona, &1.dominant_pattern})
      |> Enum.take(2)
      |> Enum.map(fn cluster ->
        "Validate whether #{cluster.persona} interpret the scenario through \"#{cluster.dominant_pattern}\"."
      end)

    assumption_checks =
      assumptions
      |> Enum.take(2)
      |> Enum.map(fn
        %{"statement" => statement} -> "Test the assumption: #{statement}"
        %{statement: statement} -> "Test the assumption: #{statement}"
        statement when is_binary(statement) -> "Test the assumption: #{statement}"
        other -> "Review the recorded assumption: #{inspect(other)}"
      end)

    coverage_check =
      if coverage["unmodelled_population"] > 0.01,
        do: ["Recruit evidence for the unmodelled population before making a launch commitment."],
        else: []

    (uncertainty_checks ++ assumption_checks ++ coverage_check)
    |> Enum.uniq()
    |> Enum.take(5)
    |> case do
      [] -> ["Collect one observed outcome and compare it with this run before acting at scale."]
      recommendations -> recommendations
    end
  end

  defp uncertainty_note(confidence, coverage, snapshot) do
    modeled = percentage(coverage["modeled_population"])

    "Directional result evaluated at #{snapshot.label}; #{modeled} of the population is explicitly modeled. Confidence is #{percentage(confidence)} and should be recalibrated with observed outcomes."
  end

  defp markdown(
         study,
         metrics,
         confidence,
         snapshot,
         assumptions,
         evidence_map,
         coverage,
         behavior_drivers,
         resistance_drivers,
         recommendations
       ) do
    """
    # #{study.question}

    ## Directional forecast at #{snapshot.label}

    #{summary(metrics, confidence, snapshot)} This is a directional model, not a certainty.

    ## Outcome mix

    #{Enum.map_join(@actions, "\n", &"- #{String.capitalize(action_label(&1))}: #{percentage(metric(metrics, &1))}")}

    ## Behavior drivers

    #{driver_lines(behavior_drivers)}

    ## Resistance drivers

    #{driver_lines(resistance_drivers)}

    ## Recommended validation

    #{Enum.map_join(recommendations, "\n", &"- #{&1}")}

    ## Assumptions

    #{assumption_lines(assumptions)}

    ## Model coverage

    - Modeled population: #{percentage(coverage["modeled_population"])}
    - Unmodelled population: #{percentage(coverage["unmodelled_population"])}

    ## Grounding mix

    - Direct workspace evidence: #{Map.get(evidence_map, "direct_user_data", 0)}
    - External research: #{Map.get(evidence_map, "external_research", 0)}
    - Explicit assumptions: #{Map.get(evidence_map, "assumptions", 0)}
    """
  end

  defp driver_lines([]), do: "- No distinct driver reached this outcome in the evaluated tick."

  defp driver_lines(drivers) do
    Enum.map_join(drivers, "\n", fn driver ->
      "- #{driver.driver} — #{driver.impact} Confidence #{percentage(driver.confidence)}."
    end)
  end

  defp normalize_coverage(coverage) when is_map(coverage) do
    %{
      "modeled_population" =>
        numeric(
          Map.get(coverage, "modeled_population", Map.get(coverage, :modeled_population)),
          1.0
        ),
      "unmodelled_population" =>
        numeric(
          Map.get(coverage, "unmodelled_population", Map.get(coverage, :unmodelled_population)),
          0.0
        )
    }
  end

  defp normalize_coverage(_coverage),
    do: %{"modeled_population" => 1.0, "unmodelled_population" => 0.0}

  defp evidence_map(source_mix, assumptions) when is_map(source_mix) do
    %{
      "direct_user_data" =>
        Map.get(
          source_mix,
          "direct_user_data",
          Map.get(source_mix, :direct_user_data, Map.get(source_mix, "user_data", 0))
        ),
      "external_research" =>
        Map.get(source_mix, "external_research", Map.get(source_mix, :external_research, 0)),
      "assumptions" =>
        max(
          Map.get(source_mix, "assumptions", Map.get(source_mix, :assumptions, 0)),
          length(assumptions)
        )
    }
  end

  defp evidence_map(_source_mix, assumptions) do
    %{"direct_user_data" => 0, "external_research" => 0, "assumptions" => length(assumptions)}
  end

  defp metric(metrics, key),
    do: Map.get(metrics, key) || Map.get(metrics, Map.get(@action_atoms, key)) || 0.0

  defp action_label("ignore"), do: "wait"
  defp action_label(action), do: action
  defp percentage(value), do: "#{round(numeric(value, 0.0) * 100)}%"
  defp assumption_lines([]), do: "- No additional assumptions recorded."

  defp assumption_lines(assumptions) do
    Enum.map_join(assumptions, "\n", fn
      %{"statement" => statement} -> "- #{statement}"
      %{statement: statement} -> "- #{statement}"
      statement when is_binary(statement) -> "- #{statement}"
      other -> "- #{inspect(other)}"
    end)
  end

  defp average([]), do: 0.0
  defp average(values), do: Float.round(Enum.sum(values) / length(values), 2)
  defp numeric(value, _default) when is_number(value), do: value * 1.0
  defp numeric(_value, default), do: default

  defp study_confidence(study) do
    case Map.get(study, :confidence) do
      value when is_number(value) and value > 1 -> value / 100
      value when is_number(value) -> value
      _ -> 0.5
    end
  end
end
