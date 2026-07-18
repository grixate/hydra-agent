defmodule HydraAgent.Simulations.ContextBuilder do
  @moduledoc "Builds a deterministic, inspectable Context Pack contract."

  alias HydraAgent.Simulations.{ContentHash, SimulationVersion, UntrustedText}

  @grounding_classes ~w(user_data user_document external_source analogue model_prior assumption)
  @max_sources 60
  @max_claims 120
  @max_assumptions 40
  @max_gaps 40

  @quick_lanes [
    {"world_context",
     %{
       "en" => "Relevant institutions, constraints, and operating context",
       "ru" => "Значимые институты, ограничения и рабочий контекст"
     }},
    {"behavioral_mechanisms",
     %{
       "en" => "Observed mechanisms that may shape agent behavior",
       "ru" => "Наблюдаемые механизмы, влияющие на поведение агентов"
     }},
    {"analogues",
     %{
       "en" => "Comparable situations and their limits",
       "ru" => "Сопоставимые ситуации и границы аналогии"
     }},
    {"counter_evidence",
     %{
       "en" => "Evidence that challenges the obvious direction",
       "ru" => "Данные, ставящие под сомнение очевидный сценарий"
     }}
  ]

  def grounding_classes, do: @grounding_classes

  def build(%SimulationVersion{} = version, opts \\ []) do
    inputs = version.inputs || %{}
    normalized = version.normalized_input || %{}
    cutoff = parse_date(normalized["historical_cutoff"])
    strict_cutoff = normalized["strict_historical_cutoff"] == true
    interpretation = interpretation(version, normalized)
    research_output = Keyword.get(opts, :research_output)
    base_pack = Keyword.get(opts, :base_context_pack)
    excluded_ids = opts |> Keyword.get(:excluded_source_ids, []) |> MapSet.new()

    {input_sources, input_claims} = input_material(inputs)

    {research_sources, research_claims, research_assumptions, research_diagnostics} =
      research_material(research_output, cutoff, strict_cutoff)

    pending_sources = pending_url_sources(inputs)

    sources =
      (input_sources ++ research_sources ++ pack_list(base_pack, :sources) ++ pending_sources)
      |> Enum.uniq_by(& &1["id"])
      |> Enum.reject(&MapSet.member?(excluded_ids, &1["id"]))
      |> Enum.take(@max_sources)
      |> Enum.sort_by(& &1["id"])

    source_ids = sources |> Enum.map(& &1["id"]) |> MapSet.new()

    prior_claims = model_prior_claims(version, interpretation)

    grounded_claims =
      (input_claims ++ research_claims ++ pack_list(base_pack, :claims))
      |> Enum.reject(&(&1["grounding_class"] == "model_prior"))
      |> Enum.reject(fn claim ->
        source_id = claim["source_id"]
        source_id && not MapSet.member?(source_ids, source_id)
      end)
      |> Enum.uniq_by(& &1["id"])

    claims =
      (Enum.take(grounded_claims, @max_claims - length(prior_claims)) ++ prior_claims)
      |> Enum.uniq_by(& &1["id"])
      |> Enum.sort_by(& &1["id"])

    assumptions =
      (default_assumptions(version, interpretation) ++
         research_assumptions ++ pack_list(base_pack, :assumptions))
      |> Enum.uniq_by(& &1["id"])
      |> Enum.take(@max_assumptions)
      |> Enum.sort_by(& &1["id"])

    plan = effective_research_plan(interpretation, research_output, base_pack, version.locale)

    retrieval_status =
      effective_retrieval_status(research_output, research_diagnostics, base_pack)

    effective_diagnostics = Map.put(research_diagnostics, :status, retrieval_status)

    gaps =
      gaps(sources, claims, effective_diagnostics, cutoff, excluded_ids, version.locale)
      |> merge_preserved_gaps(base_pack, research_output)

    status = status(claims, effective_diagnostics)
    confidence = confidence(claims, assumptions, effective_diagnostics)

    base_metadata = pack_map(base_pack, :research_metadata)
    provider_calls = non_negative_integer(base_metadata["provider_calls"])
    provider_calls = provider_calls + research_diagnostics.provider_calls

    completed_lanes = Enum.count(plan, &(&1["status"] == "complete"))

    failed_lanes =
      plan
      |> Enum.filter(&(&1["status"] == "failed"))
      |> Enum.map(& &1["lane"])
      |> Enum.sort()

    contract = %{
      "interpretation" =>
        Map.put(interpretation, "research_questions", Enum.map(plan, & &1["purpose"])),
      "scope" => %{
        "geography" => normalized["geography"],
        "horizon" => normalized["horizon"],
        "locale" => version.locale,
        "population_size" => version.population_size,
        "strict_historical_cutoff" => strict_cutoff
      },
      "research_plan" => plan,
      "sources" => sources,
      "claims" => claims,
      "assumptions" => assumptions,
      "gaps" => gaps,
      "research_metadata" =>
        %{
          "preset" => get_in(version.research_settings || %{}, ["preset"]) || "quick",
          "provider_calls" => provider_calls,
          "completed_lanes" => completed_lanes,
          "failed_lanes" => failed_lanes,
          "failed_source_count" => length(research_diagnostics.source_failures),
          "excluded_after_cutoff" =>
            non_negative_integer(base_metadata["excluded_after_cutoff"]) +
              research_diagnostics.excluded_after_cutoff,
          "excluded_unknown_dates" =>
            non_negative_integer(base_metadata["excluded_unknown_dates"]) +
              research_diagnostics.excluded_unknown_dates,
          "suspicious_source_count" => Enum.count(sources, & &1["review_required"]),
          "excluded_source_ids" => excluded_ids |> MapSet.to_list() |> Enum.sort(),
          "retrieval_status" => retrieval_status,
          "protocol_version" => "hydra-context/v1"
        }
        |> maybe_preserve_rebuild_required(base_metadata),
      "historical_cutoff" => cutoff && Date.to_iso8601(cutoff),
      "status" => status,
      "confidence" => confidence
    }

    {:ok, Map.put(contract, "content_hash", ContentHash.digest(contract))}
  end

  def rebuild_without(pack, source_id) when is_binary(source_id) do
    locale = pack.scope["locale"] || "en"
    sources = Enum.reject(pack.sources, &(&1["id"] == source_id))
    claims = Enum.reject(pack.claims, &(&1["source_id"] == source_id))

    excluded =
      [source_id | List.wrap(pack.research_metadata["excluded_source_ids"])]
      |> Enum.uniq()
      |> Enum.sort()

    gaps =
      [
        %{
          "id" => stable_id("gap", "excluded:#{source_id}"),
          "kind" => "source_excluded",
          "statement" => source_excluded_gap(locale),
          "source_id" => source_id
        }
        | pack.gaps
      ]
      |> Enum.uniq_by(& &1["id"])
      |> bound_gaps()

    gaps =
      if sourced_claims?(claims) do
        gaps
      else
        [no_sourced_gap(locale) | gaps]
        |> Enum.uniq_by(& &1["id"])
        |> bound_gaps()
      end

    status = if sourced_claims?(claims), do: pack.status, else: "partial"
    confidence = recompute_confidence(claims, pack.assumptions, status)

    contract = %{
      "interpretation" => pack.interpretation,
      "scope" => pack.scope,
      "research_plan" => pack.research_plan,
      "sources" => sources,
      "claims" => claims,
      "assumptions" => pack.assumptions,
      "gaps" => gaps,
      "research_metadata" =>
        (pack.research_metadata || %{})
        |> Map.put("excluded_source_ids", excluded)
        |> Map.put("rebuild_required", true),
      "historical_cutoff" => pack.historical_cutoff && Date.to_iso8601(pack.historical_cutoff),
      "status" => status,
      "confidence" => confidence
    }

    {:ok, Map.put(contract, "content_hash", ContentHash.digest(contract))}
  end

  defp interpretation(version, normalized) do
    question = String.trim(version.question)
    normalized_question = String.trim_trailing(question, "?")

    %{
      "world" => String.slice(normalized_question, 0, 280),
      "primary_question" => question,
      "agent_types" => infer_agent_types(question),
      "candidate_resources" => infer_resources(question),
      "candidate_actions" => infer_actions(question),
      "geography" => normalized["geography"],
      "horizon" => normalized["horizon"],
      "missing_inputs" => missing_inputs(normalized)
    }
  end

  defp infer_agent_types(question) do
    q = String.downcase(question)

    cond do
      contains_any?(q, ~w(employee employees manager managers staff сотрудник сотрудники)) ->
        ["employee", "manager", "informal_influencer"]

      contains_any?(q, ~w(customer customers consumer consumers buyer buyers клиент клиенты)) ->
        ["participant", "provider", "peer_influencer"]

      true ->
        ["participant", "decision_maker", "influencer"]
    end
  end

  defp infer_resources(question) do
    q = String.downcase(question)
    base = ["time", "information", "influence"]

    base =
      if contains_any?(q, ~w(trust privacy monitoring доверие приватность)),
        do: ["trust", "autonomy" | base],
        else: base

    base =
      if contains_any?(q, ~w(cost price budget money цена бюджет)),
        do: ["budget" | base],
        else: base

    base |> Enum.uniq() |> Enum.sort()
  end

  defp infer_actions(question) do
    q = String.downcase(question)
    base = ["adopt", "delay", "resist", "influence_others"]

    base =
      if contains_any?(q, ~w(policy rule mandatory обязательный)),
        do: ["comply_reluctantly" | base],
        else: base

    base |> Enum.uniq() |> Enum.sort()
  end

  defp missing_inputs(normalized) do
    []
    |> maybe_missing(normalized["geography"], "geography")
    |> maybe_missing(normalized["horizon"], "horizon")
    |> Enum.reverse()
  end

  defp maybe_missing(items, value, field) when value in [nil, ""], do: [field | items]
  defp maybe_missing(items, _value, _field), do: items

  defp input_material(inputs) do
    notes = inputs["notes"]

    {note_sources, note_claims} =
      if is_binary(notes) and String.trim(notes) != "" do
        material = source_material("user_data", "User notes", notes, "user_data", nil)
        {[material.source], List.wrap(material.claim)}
      else
        {[], []}
      end

    {file_sources, file_claims} =
      inputs
      |> Map.get("files", [])
      |> Enum.reduce({[], []}, fn file, {sources, claims} ->
        material =
          source_material(
            "user_document",
            file["filename"] || "Uploaded document",
            file["text"] || "",
            "user_document",
            file["sha256"]
          )

        {[material.source | sources], List.wrap(material.claim) ++ claims}
      end)

    {note_sources ++ Enum.reverse(file_sources), note_claims ++ Enum.reverse(file_claims)}
  end

  defp source_material(kind, title, text, grounding_class, supplied_hash) do
    sanitized = UntrustedText.sanitize(text)
    hash = supplied_hash || ContentHash.digest(%{"kind" => kind, "text" => sanitized["text"]})
    id = "source-#{String.slice(hash, 0, 16)}"
    quarantined = kind == "user_document" and sanitized["review_required"]

    source = %{
      "id" => id,
      "kind" => kind,
      "title" => String.slice(title, 0, 300),
      "uri" => nil,
      "published_at" => nil,
      "content_hash" => hash,
      "excerpt" => UntrustedText.excerpt(sanitized["text"], 600),
      "status" => if(quarantined, do: "review_required", else: "active"),
      "instruction_flags" => sanitized["flags"],
      "review_required" => quarantined
    }

    claim =
      if quarantined or source["excerpt"] == "" do
        nil
      else
        claim(id, source["excerpt"], grounding_class, id, 0.75, [])
      end

    %{source: source, claim: claim}
  end

  defp pending_url_sources(inputs) do
    inputs
    |> Map.get("urls", [])
    |> Enum.map(fn entry ->
      uri = entry["uri"]
      id = stable_id("source", uri)

      %{
        "id" => id,
        "kind" => "external_source",
        "title" => URI.parse(uri).host || "External source",
        "uri" => uri,
        "published_at" => nil,
        "content_hash" => ContentHash.digest(uri),
        "excerpt" => nil,
        "status" => "pending",
        "instruction_flags" => [],
        "review_required" => false
      }
    end)
  end

  defp research_material(nil, _cutoff, _strict_cutoff),
    do: {[], [], [], empty_diagnostics()}

  defp research_material(output, cutoff, strict_cutoff) when is_map(output) do
    failures = value(output, :failures, [])
    source_failures = value(output, :source_failures, [])

    {sources, excluded_after_cutoff, excluded_unknown_dates} =
      output
      |> value(:sources, [])
      |> Enum.reduce({[], 0, 0}, fn raw, {sources, excluded, unknown} ->
        published_at = raw |> value(:metadata, %{}) |> value("published_at") |> parse_date()

        cond do
          cutoff && published_at && Date.after?(published_at, cutoff) ->
            {sources, excluded + 1, unknown}

          cutoff && strict_cutoff && is_nil(published_at) ->
            {sources, excluded, unknown + 1}

          true ->
            case research_source(raw, published_at) do
              nil -> {sources, excluded, unknown}
              source -> {[source | sources], excluded, unknown}
            end
        end
      end)

    sources = Enum.reverse(sources)
    source_by_reference = Map.new(sources, &{&1["legacy_reference"], &1})

    {claims, assumptions} =
      output
      |> value(:evidence, [])
      |> Enum.reduce({[], []}, fn item, {claims, assumptions} ->
        statement = value(item, :claim, "")
        grounding = value(item, :grounding_level, "external_research")
        source_reference = value(item, :source_reference)
        source = source_by_reference[source_reference]
        lane_tags = item |> value(:tags, []) |> List.wrap()

        cond do
          grounding == "assumption" ->
            assumption = assumption(statement, "research_hypothesis")
            {claims, [assumption | assumptions]}

          is_nil(source) or source["review_required"] ->
            {claims, assumptions}

          true ->
            grounding_class =
              if "competitor_analogue" in lane_tags, do: "analogue", else: "external_source"

            confidence = numeric(value(item, :confidence_score), 0.55)
            flags = source["instruction_flags"]

            {[
               claim(source["id"], statement, grounding_class, source["id"], confidence, flags)
               | claims
             ], assumptions}
        end
      end)

    plan = value(output, :plan, [])
    completed = max(length(plan) - length(failures), 0)

    diagnostics = %{
      provider_calls: length(plan) + non_negative_integer(value(output, :direct_retrieval_calls)),
      completed_lanes: completed,
      failed_lanes: Enum.map(failures, &to_string(value(&1, :lane, "unknown"))),
      source_failures:
        Enum.map(source_failures, fn failure ->
          %{
            "source_id" => value(failure, :source_id),
            "reason" => to_string(value(failure, :reason, "unavailable_source"))
          }
        end),
      excluded_after_cutoff: excluded_after_cutoff,
      excluded_unknown_dates: excluded_unknown_dates,
      status: research_status(plan, failures, sources, source_failures)
    }

    {Enum.sort_by(sources, & &1["id"]), Enum.reverse(claims), Enum.reverse(assumptions),
     diagnostics}
  end

  defp research_source(raw, published_at) do
    text = value(raw, :parsed_text, "")
    sanitized = UntrustedText.sanitize(text)
    uri = canonical_https_uri(value(raw, :uri))

    if is_nil(uri) do
      nil
    else
      legacy_reference = value(raw, :reference, uri)
      id = stable_id("source", uri)

      %{
        "id" => id,
        "legacy_reference" => legacy_reference,
        "kind" => "external_source",
        "title" =>
          String.slice(value(raw, :title, URI.parse(uri).host || "External source"), 0, 300),
        "uri" => uri,
        "published_at" => published_at && Date.to_iso8601(published_at),
        "content_hash" => value(raw, :content_hash, ContentHash.digest(sanitized["text"])),
        "excerpt" => UntrustedText.excerpt(sanitized["text"], 600),
        "status" => if(sanitized["review_required"], do: "review_required", else: "active"),
        "instruction_flags" => sanitized["flags"],
        "review_required" => sanitized["review_required"]
      }
    end
  end

  defp research_plan(interpretation, nil, locale) do
    context = interpretation["world"]

    Enum.map(@quick_lanes, fn {lane, purpose_by_locale} ->
      purpose = purpose_by_locale[locale] || purpose_by_locale["en"]

      %{
        "lane" => lane,
        "purpose" => purpose,
        "safe_query" => String.slice("#{context} #{purpose}", 0, 500),
        "status" => "not_run"
      }
    end)
  end

  defp research_plan(interpretation, output, locale) do
    failures =
      output
      |> value(:failures, [])
      |> Enum.map(&to_string(value(&1, :lane, "unknown")))
      |> MapSet.new()

    case value(output, :plan, []) do
      [] ->
        research_plan(interpretation, nil, locale)

      plan ->
        plan
        |> Enum.take(12)
        |> Enum.map(fn lane ->
          lane_name = to_string(value(lane, :lane, "unknown"))
          fallback = to_string(value(lane, :purpose, "Bounded context retrieval"))

          %{
            "lane" => lane_name,
            "purpose" => localized_lane_purpose(lane_name, locale, fallback),
            "safe_query" => String.slice(to_string(value(lane, :safe_query, "")), 0, 1_000),
            "status" => if(MapSet.member?(failures, lane_name), do: "failed", else: "complete")
          }
        end)
    end
  end

  defp effective_research_plan(interpretation, research_output, base_pack, locale) do
    base_plan = pack_list(base_pack, :research_plan)
    output_plan = research_output && value(research_output, :plan, [])

    if base_plan != [] and (is_nil(research_output) or output_plan == []) do
      base_plan
    else
      research_plan(interpretation, research_output, locale)
    end
  end

  defp effective_retrieval_status(research_output, diagnostics, base_pack) do
    base_status = pack_map(base_pack, :research_metadata)["retrieval_status"]
    output_plan = research_output && value(research_output, :plan, [])

    cond do
      diagnostics.failed_lanes != [] or diagnostics.source_failures != [] -> "partial"
      is_nil(research_output) -> base_status || diagnostics.status
      output_plan == [] -> base_status || diagnostics.status
      true -> diagnostics.status
    end
  end

  defp merge_preserved_gaps(gaps, nil, _research_output), do: gaps

  defp merge_preserved_gaps(gaps, base_pack, research_output) do
    preserved =
      base_pack
      |> pack_list(:gaps)
      |> Enum.filter(fn gap ->
        is_nil(research_output) or gap["kind"] in ~w(historical_cutoff source_excluded)
      end)

    (gaps ++ preserved)
    |> Enum.uniq_by(& &1["id"])
    |> bound_gaps()
  end

  defp model_prior_claims(version, interpretation) do
    locale = version.locale

    [
      claim(
        "model-prior-heterogeneity",
        if(locale == "ru",
          do:
            "Симулируемые агенты могут различаться целями, ограничениями, информацией и готовностью действовать.",
          else:
            "Simulated agents may differ in goals, constraints, information, and willingness to act."
        ),
        "model_prior",
        nil,
        0.35,
        []
      ),
      claim(
        "model-prior-feedback",
        feedback_prior(locale, interpretation["horizon"] || version.normalized_input["horizon"]),
        "model_prior",
        nil,
        0.35,
        []
      )
    ]
  end

  defp default_assumptions(version, interpretation) do
    locale = version.locale

    base = [
      assumption(
        if(locale == "ru",
          do:
            "Популяция содержит значимую поведенческую неоднородность, которую нельзя вывести только из числа агентов.",
          else:
            "The population contains meaningful behavioral heterogeneity that cannot be inferred from agent count alone."
        ),
        "conservative_default"
      )
    ]

    base =
      if interpretation["horizon"] in [nil, ""] do
        [
          assumption(
            if(locale == "ru",
              do:
                "До определения горизонта в сценарии симуляция использует ограниченный горизонт по умолчанию.",
              else:
                "The simulation will use a bounded default time horizon until the Script defines one."
            ),
            "missing_horizon"
          )
          | base
        ]
      else
        base
      end

    if version.normalized_input["geography"] in [nil, ""] do
      [
        assumption(
          if(locale == "ru",
            do:
              "Ни одно правовое или культурное утверждение, зависящее от географии, не считается установленным.",
            else: "No geography-specific legal or cultural claim is treated as established."
          ),
          "missing_geography"
        )
        | base
      ]
    else
      base
    end
  end

  defp gaps(sources, claims, diagnostics, cutoff, excluded_ids, locale) do
    gaps =
      Enum.map(excluded_ids, fn source_id ->
        %{
          "id" => stable_id("gap", "excluded:#{source_id}"),
          "kind" => "source_excluded",
          "statement" => source_excluded_gap(locale),
          "source_id" => source_id
        }
      end)

    gaps =
      if sourced_claims?(claims) do
        gaps
      else
        [no_sourced_gap(locale) | gaps]
      end

    gaps =
      if Enum.any?(sources, &(&1["status"] == "pending")) do
        [
          %{
            "id" => stable_id("gap", "pending-urls"),
            "kind" => "pending_sources",
            "statement" =>
              if(locale == "ru",
                do: "Одна или несколько сохранённых ссылок ещё не загружены.",
                else: "One or more saved URLs have not been retrieved."
              )
          }
          | gaps
        ]
      else
        gaps
      end

    gaps =
      if diagnostics.status == "not_run" do
        [
          %{
            "id" => stable_id("gap", "research-not-run"),
            "kind" => "research_not_run",
            "statement" =>
              if(locale == "ru",
                do:
                  "Ограниченное исследование ещё не выполнялось; пакет использует предоставленный контекст, модельные предпосылки и допущения.",
                else:
                  "Bounded research has not run; the Pack currently uses supplied context, model priors, and assumptions."
              )
          }
          | gaps
        ]
      else
        gaps
      end

    gaps =
      Enum.reduce(diagnostics.failed_lanes, gaps, fn lane, acc ->
        [
          %{
            "id" => stable_id("gap", "failed-lane:#{lane}"),
            "kind" => "failed_research_lane",
            "lane" => lane,
            "statement" =>
              if(locale == "ru",
                do: "Этот исследовательский запрос завершился ошибкой, не заблокировав пакет.",
                else: "This research lane failed without blocking the Context Pack."
              )
          }
          | acc
        ]
      end)

    gaps =
      Enum.reduce(diagnostics.source_failures, gaps, fn failure, acc ->
        [
          %{
            "id" =>
              stable_id(
                "gap",
                "source-failure:#{failure["source_id"]}:#{failure["reason"]}"
              ),
            "kind" => "source_retrieval_failed",
            "source_id" => failure["source_id"],
            "statement" =>
              if(locale == "ru",
                do: "Сохранённый источник не удалось безопасно загрузить.",
                else: "A saved source could not be retrieved safely."
              )
          }
          | acc
        ]
      end)

    gaps =
      if diagnostics.excluded_after_cutoff > 0 do
        [
          %{
            "id" => stable_id("gap", "cutoff:#{cutoff}"),
            "kind" => "historical_cutoff",
            "statement" => cutoff_gap(locale, diagnostics.excluded_after_cutoff)
          }
          | gaps
        ]
      else
        gaps
      end

    gaps =
      if diagnostics.excluded_unknown_dates > 0 do
        [
          %{
            "id" => stable_id("gap", "cutoff-unknown:#{cutoff}"),
            "kind" => "historical_cutoff",
            "statement" => cutoff_unknown_gap(locale, diagnostics.excluded_unknown_dates)
          }
          | gaps
        ]
      else
        gaps
      end

    gaps |> Enum.uniq_by(& &1["id"]) |> bound_gaps()
  end

  defp claim(seed, statement, grounding_class, source_id, confidence, flags) do
    statement =
      statement |> UntrustedText.sanitize() |> Map.fetch!("text") |> UntrustedText.excerpt()

    %{
      "id" => stable_id("claim", "#{seed}:#{statement}:#{grounding_class}"),
      "statement" => statement,
      "grounding_class" => grounding_class,
      "source_id" => source_id,
      "confidence" => confidence |> max(0.0) |> min(1.0) |> Float.round(3),
      "influences" => [],
      "instruction_flags" => flags
    }
  end

  defp assumption(statement, rationale) do
    %{
      "id" => stable_id("assumption", "#{rationale}:#{statement}"),
      "statement" => statement,
      "grounding_class" => "assumption",
      "rationale" => rationale,
      "visible" => true
    }
  end

  defp status(claims, diagnostics) do
    if sourced_claims?(claims) and diagnostics.failed_lanes == [] and
         diagnostics.status == "complete",
       do: "ready",
       else: "partial"
  end

  defp sourced_claims?(claims) do
    Enum.any?(
      claims,
      &(&1["grounding_class"] in ~w(user_data user_document external_source analogue))
    )
  end

  defp confidence(claims, assumptions, diagnostics) do
    status = status(claims, diagnostics)
    recompute_confidence(claims, assumptions, status)
  end

  defp recompute_confidence(claims, assumptions, status) do
    values =
      Enum.map(claims, &numeric(&1["confidence"], 0.2)) ++ Enum.map(assumptions, fn _ -> 0.2 end)

    average = if values == [], do: 0.0, else: Enum.sum(values) / length(values)
    average = if status == "partial", do: min(average, 0.55), else: min(average, 0.9)
    Float.round(average, 3)
  end

  defp empty_diagnostics do
    %{
      provider_calls: 0,
      completed_lanes: 0,
      failed_lanes: [],
      source_failures: [],
      excluded_after_cutoff: 0,
      excluded_unknown_dates: 0,
      status: "not_run"
    }
  end

  defp research_status([], _failures, _sources, _source_failures), do: "not_run"

  defp research_status(_plan, [], sources, []) when sources != [],
    do: "complete"

  defp research_status(_plan, _failures, _sources, _source_failures), do: "partial"

  defp canonical_https_uri(uri) when is_binary(uri) do
    with {:ok, %URI{} = parsed} <- URI.new(uri),
         true <- parsed.scheme == "https",
         true <- is_binary(parsed.host) and parsed.host != "",
         true <- is_nil(parsed.userinfo),
         true <- is_nil(parsed.port) or parsed.port == 443,
         true <- public_hostname?(parsed.host) do
      %URI{parsed | host: String.downcase(parsed.host), port: nil, fragment: nil}
      |> URI.to_string()
    else
      _ -> nil
    end
  end

  defp canonical_https_uri(_uri), do: nil

  defp public_hostname?(host) do
    downcased = String.downcase(host)

    String.contains?(downcased, ".") and
      downcased not in ["localhost", "localhost.localdomain"] and
      not Enum.any?(~w(.local .localhost .internal .lan), &String.ends_with?(downcased, &1)) and
      match?({:error, _}, :inet.parse_address(String.to_charlist(host)))
  end

  defp localized_lane_purpose(lane, "ru", fallback) do
    case lane do
      "market_context" -> "Категория, география и рабочий контекст"
      "competitor_analogue" -> "Сопоставимые запуски и их результаты"
      "behavioral_research" -> "Наблюдаемые мотивы, барьеры и привычки"
      "regulatory" -> "Правовые, институциональные и локальные ограничения"
      "recent_news" -> "Недавние изменения, способные повлиять на прогноз"
      "local_language" -> "Локальная терминология и настроения"
      "negative_evidence" -> "Критика, сопротивление, неудачи и препятствия"
      _lane -> fallback
    end
  end

  defp localized_lane_purpose(_lane, _locale, fallback), do: fallback

  defp feedback_prior("ru", horizon) do
    horizon = horizon || "моделируемого горизонта"
    "Реакции могут меняться под влиянием социальных связей и обратной связи в течение #{horizon}."
  end

  defp feedback_prior(_locale, horizon) do
    horizon = horizon || "the modeled horizon"
    "Responses may change through social influence and feedback during #{horizon}."
  end

  defp source_excluded_gap("ru") do
    "Источник исключён; последующие артефакты должны быть пересобраны из этой версии пакета контекста."
  end

  defp source_excluded_gap(_locale) do
    "A source was excluded; downstream artifacts must rebuild from this Context Pack version."
  end

  defp no_sourced_gap(locale) do
    %{
      "id" => stable_id("gap", "no-sourced-evidence"),
      "kind" => "sourced_evidence",
      "statement" =>
        if(locale == "ru",
          do:
            "Активных утверждений с источниками нет; пакет остаётся пригодным благодаря видимым предпосылкам и допущениям.",
          else:
            "No active sourced claim is available; the Pack remains usable with visible priors and assumptions."
        )
    }
  end

  defp cutoff_gap("ru", count) do
    "Источников, опубликованных после исторической отсечки и поэтому исключённых: #{count}."
  end

  defp cutoff_gap(_locale, count) do
    "#{count} source(s) published after the historical cutoff were excluded."
  end

  defp cutoff_unknown_gap("ru", count) do
    "Источников без подтверждённой даты публикации, исключённых из строгой исторической реконструкции: #{count}."
  end

  defp cutoff_unknown_gap(_locale, count) do
    "#{count} source(s) without a verified publication date were excluded from strict historical replay."
  end

  defp parse_date(%Date{} = date), do: date

  defp parse_date(value) when is_binary(value) do
    case Date.from_iso8601(value) do
      {:ok, date} -> date
      _ -> nil
    end
  end

  defp parse_date(_value), do: nil

  defp stable_id(prefix, value) do
    hash = :crypto.hash(:sha256, to_string(value)) |> Base.encode16(case: :lower)
    "#{prefix}-#{String.slice(hash, 0, 16)}"
  end

  defp contains_any?(text, words), do: Enum.any?(words, &String.contains?(text, &1))

  defp numeric(value, _fallback) when is_number(value), do: value / 1
  defp numeric(_value, fallback), do: fallback

  defp non_negative_integer(value) when is_integer(value) and value >= 0, do: value
  defp non_negative_integer(_value), do: 0

  defp pack_list(nil, _field), do: []

  defp pack_list(pack, field) do
    case Map.get(pack, field) do
      value when is_list(value) -> value
      _value -> []
    end
  end

  defp pack_map(nil, _field), do: %{}

  defp pack_map(pack, field) do
    case Map.get(pack, field) do
      value when is_map(value) -> value
      _value -> %{}
    end
  end

  defp maybe_preserve_rebuild_required(metadata, %{"rebuild_required" => true}),
    do: Map.put(metadata, "rebuild_required", true)

  defp maybe_preserve_rebuild_required(metadata, _base_metadata), do: metadata

  defp bound_gaps(gaps) do
    gaps
    |> Enum.sort_by(fn gap -> {gap_priority(gap["kind"]), gap["id"]} end)
    |> Enum.take(@max_gaps)
  end

  defp gap_priority("source_excluded"), do: 0
  defp gap_priority("historical_cutoff"), do: 1
  defp gap_priority("failed_research_lane"), do: 2
  defp gap_priority("source_retrieval_failed"), do: 3
  defp gap_priority("pending_sources"), do: 4
  defp gap_priority("research_not_run"), do: 5
  defp gap_priority(_kind), do: 5

  defp value(map, key, default \\ nil)

  defp value(map, key, default) when is_map(map),
    do: Map.get(map, key, Map.get(map, to_string(key), default))

  defp value(_map, _key, default), do: default
end
