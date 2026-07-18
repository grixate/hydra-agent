defmodule HydraAgent.SimLab.Research.EvidencePipelineTest do
  use ExUnit.Case, async: true

  alias HydraAgent.SimLab.Research.{EvidencePipeline, Runner}

  @question "How might people respond to a proposed product change?"

  test "canonicalizes and deduplicates a repeated source across research lanes" do
    provider = fn _lane ->
      {:ok,
       [
         %{
           title: "Adoption evidence",
           url: "https://Evidence.Example:443/report?b=2&a=1#section",
           snippet: "Control and trust can affect adoption.",
           reliability: "medium"
         }
       ]}
    end

    output = Runner.run(@question, %{}, provider)

    assert [%{uri: "https://evidence.example/report?a=1&b=2"} = source] = output.sources
    assert source.metadata["source_occurrences"] == 7
    assert length(source.metadata["lanes"]) == 7

    assert [evidence] = output.evidence
    assert length(evidence.metadata["lane_tags"]) == 7
    assert length(evidence.metadata["provenance"]) == 7
    assert evidence.source_reference == source.reference
    assert output.context_pack.summary["missing_lanes"] == []
  end

  test "deduplicates an exact normalized claim while retaining source provenance" do
    provider = fn lane ->
      if lane.lane == "market_context" do
        {:ok,
         [
           %{
             title: "Adoption signal",
             url: "https://one.example/report",
             snippet: "Control improves trust.",
             reliability: "medium"
           },
           %{
             title: "Adoption signal Control improves trust.",
             url: "https://two.example/report",
             snippet: "",
             reliability: "high"
           }
         ]}
      else
        {:ok, []}
      end
    end

    output = Runner.run(@question, %{}, provider)

    assert length(output.sources) == 2
    assert [evidence] = output.evidence
    assert evidence.metadata["merged_candidate_count"] == 2
    assert length(evidence.metadata["provenance"]) == 2

    known_references = MapSet.new(output.sources, & &1.reference)

    assert Enum.all?(evidence.metadata["provenance"], fn provenance ->
             MapSet.member?(known_references, provenance["source_reference"])
           end)

    assert MapSet.member?(known_references, evidence.source_reference)
    assert evidence.reliability_score == 0.8
  end

  test "orders candidates by deterministic relevance, reliability, and freshness rank" do
    provider = fn lane ->
      if lane.lane == "market_context" do
        {:ok,
         [
           %{
             title: "Unrelated archival note",
             url: "https://evidence.example/low",
             snippet: "A generic observation without query terms.",
             reliability: "high"
           },
           %{
             title: lane.safe_query,
             url: "https://evidence.example/high",
             snippet: "#{lane.safe_query} observed study",
             reliability: "low"
           }
         ]}
      else
        {:ok, []}
      end
    end

    output = Runner.run(@question, %{}, provider)
    [first, second] = output.evidence

    assert first.source_ref["uri"] == "https://evidence.example/high"
    assert first.relevance_score > second.relevance_score
    assert first.metadata["aggregate_rank"] > second.metadata["aggregate_rank"]

    assert output.context_pack.summary["ranking_formula"] ==
             EvidencePipeline.ranking_formula()

    assert hd(output.context_pack.summary["ranked_candidate_summaries"])["rank"] == 1
  end

  test "caps unbounded function-provider lists per lane and overall" do
    provider = fn lane ->
      {:ok,
       Enum.map(1..1_000, fn index ->
         %{
           title: "#{lane.safe_query} result #{index}",
           url: "https://#{lane.lane}.example/#{index}",
           snippet: "Bounded candidate #{lane.lane} #{index}.",
           reliability: "medium"
         }
       end)}
    end

    output = Runner.run(@question, %{}, provider)
    limits = EvidencePipeline.limits()

    assert length(output.sources) == limits.max_candidates
    assert length(output.evidence) == limits.max_candidates

    assert output.context_pack.summary["provider_result_limit_lanes"]
           |> length() == 7

    assert output.context_pack.summary["total_result_limit_applied"]

    assert Enum.all?(output.evidence, fn evidence ->
             String.length(evidence.claim) <= limits.max_claim_chars + 1
           end)
  end

  test "sanitizes provider errors and exceptions without retaining raw internals" do
    provider = fn lane ->
      case lane.lane do
        "market_context" -> {:error, {:request_failed, "secret provider payload"}}
        "competitor_analogue" -> raise "secret exception detail"
        _other -> {:ok, []}
      end
    end

    output = Runner.run(@question, %{}, provider)

    assert output.failures == [
             %{lane: "market_context", reason: "provider_failed"},
             %{lane: "competitor_analogue", reason: "provider_failed"}
           ]

    serialized = inspect(output)
    refute serialized =~ "secret provider payload"
    refute serialized =~ "secret exception detail"
  end

  test "marks negative-lane evidence for review without declaring a contradiction" do
    provider = fn lane ->
      if lane.lane == "negative_evidence" do
        {:ok,
         [
           %{
             title: "Critical adoption report",
             url: "https://evidence.example/critical",
             snippet: "A source reports barriers that require researcher interpretation.",
             reliability: "medium"
           }
         ]}
      else
        {:ok, []}
      end
    end

    output = Runner.run(@question, %{}, provider)
    [evidence] = output.evidence
    [flag] = output.context_pack.summary["review_flags"]

    assert EvidencePipeline.adverse_review_flag() in evidence.metadata["review_flags"]
    assert flag["flag"] == EvidencePipeline.adverse_review_flag()
    assert flag["note"] =~ "human review is required"
    assert evidence.grounding_level == "external_research"
    refute evidence.grounding_level == "contradicted"
  end

  test "discards local and IP-literal result links at the pipeline boundary" do
    provider = fn lane ->
      if lane.lane == "market_context" do
        {:ok,
         [
           %{title: "Loopback", url: "https://127.0.0.1/report", snippet: "Private link"},
           %{title: "Local host", url: "https://service.local/report", snippet: "Private link"}
         ]}
      else
        {:ok, []}
      end
    end

    output = Runner.run(@question, %{}, provider)

    assert output.sources == []
    assert output.evidence == []
    assert output.context_pack.summary["discarded_candidate_count"] == 2
  end

  test "produces identical output for the same candidates in a different order" do
    candidates = [
      %{
        title: "Relevant category report",
        url: "https://evidence.example/a",
        snippet: "Category adoption context.",
        reliability: "high"
      },
      %{
        title: "Behavior report",
        url: "https://evidence.example/b",
        snippet: "Observed behavior context.",
        reliability: "medium"
      },
      %{
        title: "Recent report",
        url: "https://evidence.example/c",
        snippet: "Recent context for the proposed change.",
        reliability: "low"
      }
    ]

    provider = fn lane ->
      if lane.lane == "market_context", do: {:ok, candidates}, else: {:ok, []}
    end

    reversed_provider = fn lane ->
      if lane.lane == "market_context", do: {:ok, Enum.reverse(candidates)}, else: {:ok, []}
    end

    assert Runner.run(@question, %{}, provider) ==
             Runner.run(@question, %{}, reversed_provider)
  end

  test "normalizes publication dates into source and claim provenance" do
    provider = fn lane ->
      if lane.lane == "market_context" do
        {:ok,
         [
           %{
             title: "Archived evidence",
             url: "https://evidence.example/archive",
             snippet: "Evidence available before a historical decision.",
             published_at: "2024-01-15T08:30:00Z",
             reliability: "high"
           }
         ]}
      else
        {:ok, []}
      end
    end

    output = Runner.run(@question, %{}, provider)
    assert [source] = output.sources
    assert source.metadata["published_at"] == "2024-01-15"

    assert [evidence] = output.evidence
    assert evidence.source_ref["published_at"] == "2024-01-15"
    assert hd(evidence.metadata["provenance"])["published_at"] == "2024-01-15"
  end
end
