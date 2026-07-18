defmodule HydraAgent.SimLab.LocalContextBuilder do
  @moduledoc """
  Produces a versioned Context Pack from evidence already stored in a workspace.

  This is deliberately deterministic and offline. It never sends local source
  text anywhere, and it does not invent external findings when a research
  provider is unavailable.
  """

  @protocol_version "sim-lab-local-context/v1"

  def build(study, sources, evidence, version) when is_list(sources) and is_list(evidence) do
    dismissed_count = Enum.count(evidence, &(review_status(&1) == "dismissed"))
    evidence = Enum.reject(evidence, &(review_status(&1) == "dismissed"))
    source_mix = source_mix(evidence)

    findings =
      evidence |> Enum.sort_by(&confidence/1, :desc) |> Enum.take(6) |> Enum.map(&finding/1)

    %{
      version: version,
      summary: %{
        "research_status" => "workspace_evidence_synthesis",
        "synthesis_scope" => "stored_workspace_sources_only",
        "source_count" => length(sources),
        "evidence_count" => length(evidence),
        "reviewed_evidence_count" => Enum.count(evidence, &(review_status(&1) == "reviewed")),
        "unreviewed_evidence_count" => Enum.count(evidence, &(review_status(&1) == "unreviewed")),
        "dismissed_evidence_count" => dismissed_count,
        "domain" => study.domain,
        "audience" => study.target_audience
      },
      source_mix: source_mix,
      key_findings: findings,
      market_context: findings_for(evidence, ["market_context", "competitor_analogue"]),
      behavioral_context:
        findings_for(evidence, ["behavioral_research", "local_note", "uploaded_text"]),
      recent_context: findings_for(evidence, ["recent_news"]),
      regulatory_context: findings_for(evidence, ["regulatory"]),
      risks: risks(evidence, source_mix),
      assumptions: assumptions(source_mix),
      open_questions: open_questions(source_mix),
      simulation_implications: implications(evidence, source_mix),
      confidence: confidence(evidence),
      generated_by_protocol_version: @protocol_version,
      status: "active"
    }
  end

  defp source_mix(evidence) do
    evidence
    |> Enum.frequencies_by(&grounding/1)
    |> Map.new(fn {level, count} -> {level, count} end)
    |> Map.put_new("direct_user_data", 0)
    |> Map.put_new("external_research", 0)
    |> Map.put_new("assumptions", 0)
  end

  defp finding(item) do
    %{
      "kind" => value(item, :kind),
      "statement" => String.slice(value(item, :claim) || "", 0, 420),
      "grounding_level" => grounding(item),
      "confidence" => confidence(item),
      "simulation_impact" => value(item, :simulation_impact),
      "source_id" => value(item, :source_id),
      "review_status" => review_status(item)
    }
  end

  defp findings_for(evidence, tags) do
    evidence
    |> Enum.filter(fn item -> Enum.any?(value(item, :tags) || [], &(&1 in tags)) end)
    |> Enum.sort_by(&confidence/1, :desc)
    |> Enum.take(4)
    |> Enum.map(&finding/1)
  end

  defp risks(evidence, source_mix) do
    low_confidence_count = Enum.count(evidence, &(confidence(&1) < 0.5))
    unreviewed_count = Enum.count(evidence, &(review_status(&1) == "unreviewed"))
    external_count = Map.get(source_mix, "external_research", 0)

    [
      %{
        "kind" => "scope_boundary",
        "note" =>
          "This context pack was synthesized only from sources already stored in the workspace; no web search was run."
      }
    ] ++
      if(external_count == 0,
        do: [
          %{
            "kind" => "missing_external_context",
            "note" =>
              "Market, regulatory, and recent-event context remain unresearched until a provider is configured."
          }
        ],
        else: []
      ) ++
      if(low_confidence_count > 0,
        do: [
          %{
            "kind" => "review_needed",
            "note" =>
              "#{low_confidence_count} stored finding(s) remain low confidence and should be reviewed before changing probabilities."
          }
        ],
        else: []
      ) ++
      if(unreviewed_count > 0,
        do: [
          %{
            "kind" => "evidence_review_queue",
            "note" =>
              "#{unreviewed_count} evidence candidate(s) must be reviewed or dismissed before they can ground generated behavior."
          }
        ],
        else: []
      )
  end

  defp assumptions(source_mix) do
    if Map.get(source_mix, "assumption", 0) > 0 do
      [
        %{
          "statement" =>
            "Some stored evidence is explicitly assumption-level and should be validated before it drives a product decision."
        }
      ]
    else
      []
    end
  end

  defp open_questions(source_mix) do
    base = [
      %{
        "question" =>
          "Which stored finding would most change the adoption or resistance forecast if it were disproved?"
      }
    ]

    if Map.get(source_mix, "external_research", 0) == 0 do
      base ++
        [
          %{
            "question" =>
              "Which market, policy, or recent-event signal should be researched before a high-stakes launch decision?"
          }
        ]
    else
      base
    end
  end

  defp implications(evidence, source_mix) do
    primary =
      case Enum.max_by(evidence, &confidence/1, fn -> nil end) do
        nil ->
          "Add a finding before generating behavior rules."

        item ->
          value(item, :simulation_impact) ||
            "Link the strongest findings to behavior rules before simulation."
      end

    [
      %{"note" => primary},
      %{
        "note" =>
          "Link the strongest stored findings to personas and patterns; unlinked rules remain explicit assumptions."
      }
    ] ++
      if(Map.get(source_mix, "external_research", 0) == 0,
        do: [
          %{
            "note" =>
              "Keep forecast confidence directional until external context or direct outcome data is added."
          }
        ],
        else: []
      )
  end

  defp confidence([]), do: 0.25

  defp confidence(evidence) when is_list(evidence) do
    average = Enum.sum_by(evidence, &confidence/1) / length(evidence)
    Float.round(min(0.75, max(0.25, average)), 2)
  end

  defp confidence(item) when is_map(item) do
    recorded = value(item, :confidence_score) || 0.25
    if review_status(item) == "reviewed", do: recorded, else: min(recorded * 0.6, 0.35)
  end

  defp confidence(item), do: value(item, :confidence_score) || 0.25

  defp grounding(item), do: value(item, :grounding_level) || "assumption"

  defp review_status(item) do
    item |> value(:metadata) |> value(:review_status) || "unreviewed"
  end

  defp value(map, key) when is_map(map), do: Map.get(map, key) || Map.get(map, to_string(key))
  defp value(_map, _key), do: nil
end
