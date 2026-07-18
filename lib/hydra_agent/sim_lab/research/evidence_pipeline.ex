defmodule HydraAgent.SimLab.Research.EvidencePipeline do
  @moduledoc """
  Converts untrusted provider candidates into bounded, ranked research evidence.

  The pipeline is deliberately deterministic. It processes at most ten results
  per lane and forty results overall, extracts a short claim, canonicalizes HTTPS
  provenance, and deduplicates sources and exact normalized claims.

  Candidate ordering uses the documented aggregate rank:

      0.50 * relevance + 0.30 * reliability + 0.20 * freshness

  Relevance is token overlap between the already-abstracted safe query and the
  candidate title/excerpt. A review flag on a negative or provider-declared
  adverse lane means only "review this candidate"; it is not a factual
  contradiction determination.
  """

  alias HydraAgent.SimLab.Research.QueryAbstractor

  @max_results_per_lane 10
  @max_candidates 40
  @max_title_chars 300
  @max_source_excerpt_chars 4_000
  @max_claim_title_chars 180
  @max_claim_excerpt_chars 420
  @max_safe_query_chars 1_000
  @max_uri_chars 2_048
  @ranking_formula "0.50 relevance + 0.30 reliability + 0.20 freshness"
  @adverse_review_flag "potentially_adverse_or_conflicting_evidence"

  @stopwords MapSet.new(~w(
    a an and are as at be by for from how in into is it of on or that the their
    this to user users what when where which who will with would
  ))

  @doc "Returns the hard processing limits used for every provider type."
  def limits do
    %{
      max_results_per_lane: @max_results_per_lane,
      max_candidates: @max_candidates,
      max_claim_chars: @max_claim_title_chars + @max_claim_excerpt_chars + 2
    }
  end

  @doc "Processes ordered `{lane, provider_response}` pairs."
  def process(responses) when is_list(responses) do
    {candidates, failures, discarded, limited_lanes} = collect_candidates(responses)

    ordered_candidates = Enum.sort_by(candidates, &candidate_order/1)
    bounded_candidates = Enum.take(ordered_candidates, @max_candidates)

    {sources, source_references} = materialize_sources(bounded_candidates)

    evidence =
      bounded_candidates
      |> Enum.map(&materialize_evidence(&1, Map.fetch!(source_references, &1.id)))
      |> merge_exact_claims()
      |> Enum.sort_by(&evidence_order/1)

    %{
      sources: sources,
      evidence: evidence,
      failures: failures,
      diagnostics: %{
        discarded_candidate_count: discarded,
        provider_result_limit_lanes: Enum.sort(limited_lanes),
        total_result_limit_applied: length(ordered_candidates) > @max_candidates,
        ranking_formula: @ranking_formula,
        max_results_per_lane: @max_results_per_lane,
        max_candidates: @max_candidates
      }
    }
  end

  def ranking_formula, do: @ranking_formula
  def adverse_review_flag, do: @adverse_review_flag

  defp collect_candidates(responses) do
    Enum.reduce(responses, {[], [], 0, []}, fn {lane, response},
                                               {candidates, failures, discarded, limited_lanes} ->
      case response do
        {:ok, results} when is_list(results) ->
          {bounded_results, overflow} = Enum.split(results, @max_results_per_lane)

          {lane_candidates, lane_discarded} =
            bounded_results
            |> Enum.map(&normalize_candidate(lane, &1))
            |> Enum.reduce({[], 0}, fn
              {:ok, candidate}, {items, count} -> {[candidate | items], count}
              :discard, {items, count} -> {items, count + 1}
            end)

          limited_lanes = if overflow == [], do: limited_lanes, else: [lane.lane | limited_lanes]

          {
            Enum.reverse(lane_candidates, candidates),
            failures,
            discarded + lane_discarded,
            limited_lanes
          }

        {:error, reason} ->
          failure = %{lane: lane.lane, reason: sanitize_failure(reason)}
          {candidates, failures ++ [failure], discarded, limited_lanes}

        _other ->
          failure = %{lane: lane.lane, reason: "invalid_provider_response"}
          {candidates, failures ++ [failure], discarded, limited_lanes}
      end
    end)
  end

  defp normalize_candidate(lane, result) when is_map(result) do
    title = result |> field(:title) |> clean_text(@max_title_chars)
    snippet = result |> field(:snippet) |> clean_text(@max_source_excerpt_chars)

    title = if title == "" and snippet != "", do: "Untitled research result", else: title
    grounding_level = grounding_level(result)
    synthetic_test? = field(result, :synthetic_test) == true
    uri = canonical_uri(field(result, :url))

    cond do
      title == "" and snippet == "" ->
        :discard

      grounding_level != "assumption" and is_nil(uri) ->
        :discard

      true ->
        reliability = reliability_score(result)
        freshness = freshness_score(lane, result, grounding_level)
        relevance = relevance_score(lane.safe_query, title, snippet)
        aggregate_rank = aggregate_rank(relevance, reliability, freshness)

        content_hash =
          hash([
            source_type(grounding_level),
            normalize_claim(title),
            normalize_claim(snippet)
          ])

        review_flags = review_flags(lane, result)
        provider_mode = clean_text(field(result, :provider_mode), 120)
        provider_mode = if provider_mode == "", do: "web_search", else: provider_mode

        candidate = %{
          id:
            hash([
              lane.lane,
              uri || "",
              content_hash,
              normalize_claim(title),
              normalize_claim(snippet),
              grounding_level
            ]),
          lane: lane,
          title: title,
          snippet: snippet,
          uri: if(grounding_level == "assumption", do: nil, else: uri),
          content_hash: content_hash,
          grounding_level: grounding_level,
          source_type: source_type(grounding_level),
          source_kind: if(grounding_level == "assumption", do: "manual_note", else: "web"),
          reliability: reliability,
          reliability_label: reliability_label(result),
          relevance: relevance,
          freshness: freshness,
          confidence: confidence_score(reliability, freshness),
          aggregate_rank: aggregate_rank,
          provider_mode: provider_mode,
          synthetic_test?: synthetic_test?,
          review_flags: review_flags
        }

        {:ok, candidate}
    end
  end

  defp normalize_candidate(_lane, _result), do: :discard

  defp materialize_sources(candidates) do
    candidates
    |> source_groups()
    |> Enum.reduce({[], %{}}, fn group, {sources, references} ->
      ordered_group = Enum.sort_by(group, &candidate_order/1)
      representative = hd(ordered_group)

      identity =
        ordered_group
        |> Enum.flat_map(fn candidate ->
          ["uri:#{candidate.uri || ""}", "content:#{candidate.content_hash}"]
        end)
        |> Enum.uniq()
        |> Enum.sort()

      reference = "source:#{hash(identity)}"
      lanes = ordered_group |> Enum.map(& &1.lane.lane) |> Enum.uniq() |> Enum.sort()
      purposes = ordered_group |> Enum.map(& &1.lane.purpose) |> Enum.uniq() |> Enum.sort()

      alternate_uris =
        ordered_group
        |> Enum.map(& &1.uri)
        |> Enum.reject(&is_nil/1)
        |> Enum.uniq()
        |> Enum.sort()

      pii_audit = QueryAbstractor.analyze(representative.snippet)

      source = %{
        reference: reference,
        kind: representative.source_kind,
        title: representative.title,
        uri: representative.uri,
        content_hash: representative.content_hash,
        parsed_text: representative.snippet,
        metadata: %{
          "lane" => hd(lanes),
          "lanes" => lanes,
          "purpose" => representative.lane.purpose,
          "purposes" => purposes,
          "region" => representative.lane.region,
          "language" => representative.lane.language,
          "provider_reliability" => representative.reliability_label,
          "provider_mode" => representative.provider_mode,
          "synthetic_test" => representative.synthetic_test?,
          "entry_type" =>
            if(representative.synthetic_test?,
              do: "codex_cli_test_hypothesis",
              else: "research"
            ),
          "pii_findings" => pii_audit.findings,
          "source_occurrences" => length(ordered_group),
          "alternate_uris" => alternate_uris,
          "aggregate_rank" => representative.aggregate_rank,
          "ranking_formula" => @ranking_formula,
          "review_flags" =>
            ordered_group |> Enum.flat_map(& &1.review_flags) |> Enum.uniq() |> Enum.sort()
        },
        pii_status: if(pii_audit.changed?, do: "suspected", else: "none"),
        access_policy: %{
          "retrieval" =>
            if(representative.synthetic_test?,
              do: "local_cli_safe_queries_only",
              else: "abstracted_query_only"
            ),
          "review_required" => true,
          "synthetic_test" => representative.synthetic_test?
        },
        status: "parsed"
      }

      references =
        Enum.reduce(ordered_group, references, fn candidate, acc ->
          Map.put(acc, candidate.id, reference)
        end)

      {[source | sources], references}
    end)
    |> then(fn {sources, references} ->
      {Enum.sort_by(sources, &source_order/1), references}
    end)
  end

  defp source_groups(candidates) do
    candidates
    |> Enum.sort_by(&candidate_order/1)
    |> Enum.reduce([], fn candidate, groups ->
      {matching, remaining} =
        Enum.split_with(groups, fn group -> source_matches_group?(candidate, group) end)

      merged = [candidate | Enum.flat_map(matching, & &1)]
      [merged | remaining]
    end)
  end

  defp source_matches_group?(candidate, group) do
    Enum.any?(group, fn member ->
      candidate.source_type == member.source_type and
        ((candidate.uri != nil and candidate.uri == member.uri) or
           candidate.content_hash == member.content_hash)
    end)
  end

  defp materialize_evidence(candidate, source_reference) do
    claim = concise_claim(candidate.title, candidate.snippet)

    provenance = %{
      "source_reference" => source_reference,
      "uri" => candidate.uri || "",
      "title" => candidate.title,
      "lane" => candidate.lane.lane,
      "safe_query" => clean_text(candidate.lane.safe_query, @max_safe_query_chars),
      "provider_mode" => candidate.provider_mode
    }

    %{
      source_reference: source_reference,
      kind: "research_candidate",
      claim: claim,
      normalized_claim: normalize_claim(claim),
      source_ref: %{
        "uri" => candidate.uri || "",
        "title" => candidate.title,
        "lane" => candidate.lane.lane,
        "lanes" => [candidate.lane.lane]
      },
      grounding_level: candidate.grounding_level,
      reliability_score: candidate.reliability,
      relevance_score: candidate.relevance,
      freshness_score: candidate.freshness,
      confidence_score: candidate.confidence,
      simulation_impact: candidate.lane.expected_simulation_impact,
      tags:
        [candidate.lane.lane, "provider_candidate"] ++
          if(candidate.synthetic_test?, do: ["synthetic_test", "codex_cli"], else: []),
      metadata: %{
        "review_status" => "unreviewed",
        "safe_query" => clean_text(candidate.lane.safe_query, @max_safe_query_chars),
        "provider_mode" => candidate.provider_mode,
        "synthetic_test" => candidate.synthetic_test?,
        "aggregate_rank" => candidate.aggregate_rank,
        "ranking_formula" => @ranking_formula,
        "review_flags" => candidate.review_flags,
        "lane_tags" => [candidate.lane.lane],
        "provenance" => [provenance],
        "simulation_impacts" => [candidate.lane.expected_simulation_impact]
      }
    }
  end

  defp merge_exact_claims(evidence) do
    evidence
    |> Enum.group_by(&{&1.normalized_claim, &1.grounding_level})
    |> Enum.map(fn {_key, items} -> merge_evidence_group(items) end)
  end

  defp merge_evidence_group(items) do
    ordered = Enum.sort_by(items, &evidence_order/1)
    strongest = hd(ordered)
    lanes = ordered |> Enum.flat_map(& &1.metadata["lane_tags"]) |> Enum.uniq() |> Enum.sort()

    provenance =
      ordered
      |> Enum.flat_map(& &1.metadata["provenance"])
      |> Enum.uniq_by(fn item ->
        {item["source_reference"], item["lane"], item["safe_query"], item["provider_mode"]}
      end)
      |> Enum.sort_by(fn item ->
        {item["source_reference"], item["lane"], item["safe_query"], item["provider_mode"]}
      end)

    review_flags =
      ordered
      |> Enum.flat_map(& &1.metadata["review_flags"])
      |> Enum.uniq()
      |> Enum.sort()

    impacts =
      ordered
      |> Enum.flat_map(& &1.metadata["simulation_impacts"])
      |> Enum.uniq()
      |> Enum.sort()

    metadata =
      strongest.metadata
      |> Map.put("aggregate_rank", maximum_metadata_score(ordered, "aggregate_rank"))
      |> Map.put("lane_tags", lanes)
      |> Map.put("provenance", provenance)
      |> Map.put("review_flags", review_flags)
      |> Map.put("simulation_impacts", impacts)
      |> Map.put("merged_candidate_count", length(ordered))

    strongest
    |> Map.put(:reliability_score, maximum_score(ordered, :reliability_score))
    |> Map.put(:relevance_score, maximum_score(ordered, :relevance_score))
    |> Map.put(:freshness_score, maximum_score(ordered, :freshness_score))
    |> Map.put(:confidence_score, maximum_score(ordered, :confidence_score))
    |> Map.put(:tags, ordered |> Enum.flat_map(& &1.tags) |> Enum.uniq() |> Enum.sort())
    |> Map.put(:source_ref, Map.put(strongest.source_ref, "lanes", lanes))
    |> Map.put(:metadata, metadata)
  end

  defp maximum_score(items, key), do: items |> Enum.map(&Map.fetch!(&1, key)) |> Enum.max()

  defp maximum_metadata_score(items, key),
    do: items |> Enum.map(& &1.metadata[key]) |> Enum.max()

  defp concise_claim(title, snippet) do
    title = truncate_words(title, @max_claim_title_chars)
    excerpt = truncate_words(snippet, @max_claim_excerpt_chars)

    cond do
      title == "" -> excerpt
      excerpt == "" -> title
      true -> "#{title}: #{excerpt}"
    end
  end

  defp relevance_score(safe_query, title, snippet) do
    query_tokens = safe_query |> clean_text(@max_safe_query_chars) |> tokens()

    if MapSet.size(query_tokens) == 0 do
      0.0
    else
      title_coverage = token_coverage(query_tokens, tokens(title))
      snippet_coverage = token_coverage(query_tokens, tokens(snippet))
      Float.round(0.65 * title_coverage + 0.35 * snippet_coverage, 4)
    end
  end

  defp token_coverage(query_tokens, candidate_tokens) do
    matched = query_tokens |> MapSet.intersection(candidate_tokens) |> MapSet.size()
    matched / MapSet.size(query_tokens)
  end

  defp tokens(value) when is_binary(value) do
    ~r/[\p{L}\p{N}]+/u
    |> Regex.scan(String.downcase(value))
    |> Enum.map(&hd/1)
    |> Enum.reject(&(String.length(&1) < 3 or MapSet.member?(@stopwords, &1)))
    |> MapSet.new()
  end

  defp tokens(_value), do: MapSet.new()

  defp aggregate_rank(relevance, reliability, freshness),
    do: Float.round(0.50 * relevance + 0.30 * reliability + 0.20 * freshness, 4)

  defp confidence_score(reliability, freshness),
    do: Float.round((reliability + freshness) / 2, 2)

  defp reliability_score(result) do
    case field(result, :reliability_score) do
      value when is_number(value) -> clamp_score(value)
      _value -> reliability_from_label(field(result, :reliability))
    end
  end

  defp reliability_label(result) do
    case field(result, :reliability) do
      label when label in ["high", "medium", "low", "unknown"] -> label
      _label -> "unknown"
    end
  end

  defp reliability_from_label("high"), do: 0.8
  defp reliability_from_label("medium"), do: 0.6
  defp reliability_from_label("low"), do: 0.35
  defp reliability_from_label(_label), do: 0.35

  defp freshness_score(_lane, _result, "assumption"), do: 0.0

  defp freshness_score(lane, result, _grounding_level) do
    case field(result, :freshness_score) do
      value when is_number(value) -> clamp_score(value)
      _value when lane.freshness == "recent" -> 0.8
      _value -> 0.55
    end
  end

  defp clamp_score(value), do: value |> max(0.0) |> min(1.0) |> Float.round(4)

  defp grounding_level(result) do
    if field(result, :grounding_level) == "assumption" or field(result, :synthetic_test) == true,
      do: "assumption",
      else: "external_research"
  end

  defp source_type("assumption"), do: "assumption"
  defp source_type(_grounding_level), do: "sourced_research"

  defp review_flags(lane, result) do
    declared_semantics =
      [
        field(result, :stance),
        field(result, :source_semantics),
        field(result, :evidence_semantics)
      ]
      |> Enum.map(&(clean_text(&1, 80) |> String.downcase()))

    adverse_semantics? =
      Enum.any?(declared_semantics, fn value ->
        value in ["negative", "adverse", "critical", "conflicting", "counterevidence"]
      end)

    if lane.lane == "negative_evidence" or adverse_semantics? or
         field(result, :negative_evidence) == true,
       do: [@adverse_review_flag],
       else: []
  end

  defp canonical_uri(uri) when is_binary(uri) do
    with bounded_uri when bounded_uri != "" <- clean_text(uri, @max_uri_chars),
         {:ok, %URI{} = parsed} <- URI.new(bounded_uri),
         %URI{scheme: scheme, host: host, userinfo: nil} <- parsed,
         true <- String.downcase(scheme || "") == "https",
         true <- is_binary(host) and host != "",
         true <- public_link_hostname?(host),
         true <- is_nil(parsed.port) or parsed.port == 443 do
      canonical = %URI{
        parsed
        | scheme: "https",
          host: String.downcase(host),
          port: nil,
          path: canonical_path(parsed.path),
          query: canonical_query(parsed.query),
          fragment: nil
      }

      URI.to_string(canonical)
    else
      _ -> nil
    end
  rescue
    _error -> nil
  end

  defp canonical_uri(_uri), do: nil

  defp public_link_hostname?(host) do
    normalized = String.downcase(host)

    String.contains?(normalized, ".") and
      not match?({:ok, _address}, :inet.parse_address(String.to_charlist(normalized))) and
      not Enum.any?(
        [".local", ".localhost", ".internal", ".lan"],
        &String.ends_with?(normalized, &1)
      )
  end

  defp canonical_path(path) when path in [nil, ""], do: "/"
  defp canonical_path(path), do: path

  defp canonical_query(nil), do: nil

  defp canonical_query(query) do
    query
    |> String.split("&", trim: true)
    |> Enum.sort()
    |> Enum.join("&")
    |> case do
      "" -> nil
      sorted -> sorted
    end
  end

  defp sanitize_failure(reason) do
    cond do
      contains_atom?(reason, [:timeout, :codex_cli_timeout]) ->
        "provider_timeout"

      contains_atom?(reason, [:response_too_large, :codex_cli_output_too_large]) ->
        "provider_response_too_large"

      contains_atom?(reason, [
        :not_configured,
        :provider_credential_not_configured,
        :tavily_not_configured,
        :codex_cli_test_disabled,
        :codex_cli_not_found
      ]) ->
        "provider_not_configured"

      contains_atom?(reason, [:unauthorized, :tavily_unauthorized]) ->
        "provider_authentication_failed"

      contains_atom?(reason, [:rate_limited, :tavily_rate_limited]) ->
        "provider_rate_limited"

      contains_atom?(reason, [
        :invalid_provider_response,
        :invalid_tavily_response,
        :invalid_codex_cli_output,
        :invalid_codex_cli_runner_response,
        :incomplete_codex_cli_result,
        :invalid_research_lane
      ]) ->
        "invalid_provider_response"

      true ->
        sanitize_status_failure(reason)
    end
  end

  defp sanitize_status_failure({tag, status})
       when tag in [:provider_status, :tavily_status] and status in [401, 403],
       do: "provider_authentication_failed"

  defp sanitize_status_failure({tag, 429}) when tag in [:provider_status, :tavily_status],
    do: "provider_rate_limited"

  defp sanitize_status_failure(_reason), do: "provider_failed"

  defp contains_atom?(term, atoms), do: contains_atom?(term, atoms, 0)

  defp contains_atom?(_term, _atoms, depth) when depth > 3, do: false

  defp contains_atom?(term, atoms, _depth) when is_atom(term), do: term in atoms

  defp contains_atom?(term, atoms, depth) when is_tuple(term) do
    term
    |> Tuple.to_list()
    |> Enum.take(4)
    |> Enum.any?(&contains_atom?(&1, atoms, depth + 1))
  end

  defp contains_atom?(term, atoms, depth) when is_list(term) do
    term
    |> Enum.take(4)
    |> Enum.any?(&contains_atom?(&1, atoms, depth + 1))
  end

  defp contains_atom?(_term, _atoms, _depth), do: false

  defp field(result, key), do: Map.get(result, key) || Map.get(result, Atom.to_string(key))

  defp clean_text(value, max_chars) when is_binary(value) do
    value
    |> String.slice(0, max_chars * 2)
    |> String.replace(~r/\s+/u, " ")
    |> String.trim()
    |> String.slice(0, max_chars)
  rescue
    _error -> ""
  end

  defp clean_text(_value, _max_chars), do: ""

  defp truncate_words(value, max_chars) do
    if String.length(value) <= max_chars do
      value
    else
      truncated = String.slice(value, 0, max_chars)
      word_safe = Regex.replace(~r/\s+\S*$/u, truncated, "")
      if(word_safe == "", do: truncated, else: word_safe) <> "…"
    end
  end

  defp normalize_claim(claim) do
    claim
    |> String.downcase()
    |> String.replace(~r/[^\p{L}\p{N}\s]/u, " ")
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  end

  defp candidate_order(candidate) do
    {
      -candidate.aggregate_rank,
      -candidate.relevance,
      -candidate.reliability,
      -candidate.freshness,
      candidate.uri || "",
      candidate.title,
      candidate.id
    }
  end

  defp evidence_order(evidence) do
    {
      -evidence.metadata["aggregate_rank"],
      -evidence.relevance_score,
      -evidence.reliability_score,
      -evidence.freshness_score,
      evidence.normalized_claim,
      evidence.source_reference
    }
  end

  defp source_order(source) do
    {-source.metadata["aggregate_rank"], source.uri || "", source.title, source.reference}
  end

  defp hash(term),
    do: :crypto.hash(:sha256, :erlang.term_to_binary(term)) |> Base.encode16(case: :lower)
end
