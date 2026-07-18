defmodule HydraAgent.SimLab.Research.Runner do
  @moduledoc """
  Executes a planned web-research pass without exposing a study's raw question.

  The runner is pure: it turns provider responses into provenance-rich source,
  evidence, and context-pack attributes. Persistence and asynchronous delivery
  are deliberately separate, so each stage can be tested without a database or
  a live search provider.
  """

  alias HydraAgent.SimLab.Research.{
    EvidencePipeline,
    StudyParser,
    WebResearchPlanner
  }

  @protocol_version "sim-lab-research/v2"
  @max_context_summaries 20

  def run(question, attrs, provider, opts \\ %{}) when is_binary(question) do
    parsed = StudyParser.parse(question, attrs)
    plan = WebResearchPlanner.plan(parsed, opts)

    pipeline =
      provider
      |> search_plan(plan)
      |> EvidencePipeline.process()

    %{
      parsed_study: parsed,
      plan: plan,
      sources: pipeline.sources,
      evidence: pipeline.evidence,
      context_pack:
        build_context_pack(
          parsed,
          plan,
          pipeline.evidence,
          pipeline.failures,
          pipeline.diagnostics
        ),
      failures: pipeline.failures
    }
  end

  defp search(provider, lane) do
    try do
      if is_function(provider, 1), do: provider.(lane), else: provider.search(lane)
    rescue
      _error -> {:error, :provider_exception}
    catch
      :exit, _reason -> {:error, :provider_exit}
      _kind, _reason -> {:error, :provider_exception}
    end
  end

  defp search_plan(provider, plan) when is_function(provider, 1),
    do: Enum.map(plan, &{&1, search(provider, &1)})

  defp search_plan(provider, plan) do
    if Code.ensure_loaded?(provider) and function_exported?(provider, :search_many, 1) do
      case safe_search_many(provider, plan) do
        {:ok, results_by_lane} when is_map(results_by_lane) ->
          Enum.map(plan, fn lane -> {lane, {:ok, Map.get(results_by_lane, lane.lane, [])}} end)

        {:error, reason} ->
          Enum.map(plan, &{&1, {:error, reason}})

        other ->
          Enum.map(plan, &{&1, other})
      end
    else
      Enum.map(plan, &{&1, search(provider, &1)})
    end
  end

  defp safe_search_many(provider, plan) do
    try do
      provider.search_many(plan)
    rescue
      _error -> {:error, :provider_exception}
    catch
      :exit, _reason -> {:error, :provider_exit}
      _kind, _reason -> {:error, :provider_exception}
    end
  end

  defp build_context_pack(parsed, plan, evidence, failures, diagnostics) do
    synthetic_test? =
      evidence != [] and Enum.all?(evidence, &(&1.metadata["synthetic_test"] == true))

    missing_lanes =
      plan
      |> Enum.reject(fn lane -> Enum.any?(evidence, &(lane.lane in &1.tags)) end)
      |> Enum.map(& &1.lane)

    lane_findings =
      Enum.map(plan, fn lane ->
        lane_evidence = Enum.filter(evidence, fn item -> lane.lane in item.tags end)
        top_candidate = List.first(lane_evidence)

        %{
          "lane" => lane.lane,
          "purpose" => lane.purpose,
          "evidence_candidates" => length(lane_evidence),
          "impact" => lane.expected_simulation_impact,
          "missing" => lane_evidence == [],
          "top_aggregate_rank" => top_candidate && top_candidate.metadata["aggregate_rank"],
          "review_flags" => review_flags(lane_evidence)
        }
      end)

    sourced_evidence = Enum.reject(evidence, &(&1.grounding_level == "assumption"))
    assumption_evidence = Enum.filter(evidence, &(&1.grounding_level == "assumption"))
    context_review_flags = review_flag_summaries(evidence)

    %{
      summary: %{
        "domain" => parsed.domain,
        "audience" => parsed.target_audience,
        "behavior" => parsed.behavior,
        "research_status" => research_status(synthetic_test?, failures, missing_lanes),
        "provider_mode" => if(synthetic_test?, do: "codex_cli_test", else: "web_search"),
        "protocol_version" => @protocol_version,
        "ranked_candidate_summaries" => ranked_summaries(sourced_evidence),
        "ranked_assumption_summaries" => ranked_summaries(assumption_evidence),
        "missing_lanes" => missing_lanes,
        "review_flags" => context_review_flags,
        "source_types" => sourced_source_types(sourced_evidence),
        "assumption_count" => length(assumption_evidence),
        "discarded_candidate_count" => diagnostics.discarded_candidate_count,
        "provider_result_limit_lanes" => diagnostics.provider_result_limit_lanes,
        "total_result_limit_applied" => diagnostics.total_result_limit_applied,
        "ranking_formula" => diagnostics.ranking_formula,
        "pipeline_limits" => %{
          "max_results_per_lane" => diagnostics.max_results_per_lane,
          "max_candidates" => diagnostics.max_candidates,
          "context_summaries" => @max_context_summaries
        }
      },
      source_mix: source_mix(evidence),
      key_findings: lane_findings,
      market_context: findings_for(lane_findings, "market_context"),
      behavioral_context: findings_for(lane_findings, "behavioral_research"),
      recent_context: findings_for(lane_findings, "recent_news"),
      regulatory_context: findings_for(lane_findings, "regulatory"),
      risks:
        failure_risks(failures) ++
          review_flag_risks(context_review_flags) ++
          synthetic_test_risks(synthetic_test?) ++
          [
            %{
              "kind" => "evidence_review",
              "note" => "Retrieved candidates require researcher review."
            }
          ],
      assumptions: assumptions(assumption_evidence),
      open_questions: [
        %{"question" => "Which candidate findings are valid for this specific study?"}
      ],
      simulation_implications: Enum.map(lane_findings, &Map.take(&1, ["lane", "impact"])),
      confidence: context_confidence(evidence, failures),
      generated_by_protocol_version: @protocol_version,
      status: "active"
    }
  end

  defp ranked_summaries(evidence) do
    evidence
    |> Enum.take(@max_context_summaries)
    |> Enum.with_index(1)
    |> Enum.map(fn {item, rank} ->
      %{
        "rank" => rank,
        "source_reference" => item.source_reference,
        "title" => item.source_ref["title"],
        "excerpt" => String.slice(item.claim, 0, 280),
        "aggregate_rank" => item.metadata["aggregate_rank"],
        "reliability" => item.reliability_score,
        "relevance" => item.relevance_score,
        "freshness" => item.freshness_score,
        "lanes" => item.metadata["lane_tags"],
        "source_type" => item.grounding_level,
        "review_flags" => item.metadata["review_flags"]
      }
    end)
  end

  defp sourced_source_types(evidence) do
    evidence
    |> Enum.frequencies_by(& &1.grounding_level)
    |> Enum.sort()
    |> Map.new()
  end

  defp review_flags(evidence) do
    evidence
    |> Enum.flat_map(& &1.metadata["review_flags"])
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp review_flag_summaries(evidence) do
    evidence
    |> Enum.flat_map(& &1.metadata["review_flags"])
    |> Enum.frequencies()
    |> Enum.sort()
    |> Enum.map(fn {flag, count} ->
      %{
        "flag" => flag,
        "candidate_count" => count,
        "note" =>
          "Lane or provider semantics indicate a potentially adverse candidate; human review is required before interpreting it as conflicting evidence."
      }
    end)
  end

  defp review_flag_risks(review_flags) do
    Enum.map(review_flags, fn flag ->
      %{
        "kind" => "evidence_review_flag",
        "flag" => flag["flag"],
        "candidate_count" => flag["candidate_count"],
        "note" => flag["note"]
      }
    end)
  end

  defp failure_risks(failures) do
    Enum.map(failures, fn failure ->
      %{
        "kind" => "provider_failure",
        "lane" => failure.lane,
        "reason" => failure.reason
      }
    end)
  end

  defp findings_for(findings, lane), do: Enum.filter(findings, &(&1["lane"] == lane))

  defp research_status(true, [], []), do: "synthetic_test_hypotheses"
  defp research_status(true, _failures, _missing_lanes), do: "partial_synthetic_test_hypotheses"
  defp research_status(false, [], []), do: "complete"
  defp research_status(false, _failures, _missing_lanes), do: "partial"

  defp source_mix(evidence) do
    %{
      "external_research" => Enum.count(evidence, &(&1.grounding_level == "external_research")),
      "assumptions" => Enum.count(evidence, &(&1.grounding_level == "assumption"))
    }
  end

  defp assumptions(evidence) do
    Enum.map(evidence, fn item ->
      %{
        "statement" => item.claim,
        "source" => "Codex CLI synthetic test hypothesis",
        "review_required" => true,
        "aggregate_rank" => item.metadata["aggregate_rank"],
        "lanes" => item.metadata["lane_tags"]
      }
    end)
  end

  defp synthetic_test_risks(true) do
    [
      %{
        "kind" => "synthetic_test_only",
        "note" =>
          "Codex CLI generated hypotheses from abstracted queries; no web source was retrieved or verified."
      }
    ]
  end

  defp synthetic_test_risks(false), do: []

  defp context_confidence([], _failures), do: 0.0

  defp context_confidence(evidence, failures) do
    average = Enum.sum_by(evidence, & &1.confidence_score) / length(evidence)
    penalty = min(length(failures) * 0.05, 0.25)
    Float.round(max(average - penalty, 0.0), 2)
  end
end
