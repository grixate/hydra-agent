defmodule HydraAgent.Simulations.ContextResearch do
  @moduledoc "Runs the existing bounded retrieval pipeline for a Simulation Version."

  alias HydraAgent.SimLab.Research.{PublicUrlFetcher, Runner}
  alias HydraAgent.Simulations.{BudgetGovernor, ContentHash, SimulationVersion}

  @max_direct_concurrency 3
  @direct_timeout 15_000

  def run(%SimulationVersion{} = version, provider, opts \\ []) do
    normalized = version.normalized_input || %{}

    attrs = %{
      "domain" => "general agent simulation",
      "region" => normalized["geography"],
      "language" => version.locale,
      "target_audience" => inferred_audience(version.question),
      "research_depth" => get_in(version.research_settings || %{}, ["preset"]) || "quick"
    }

    budget_plan = Keyword.get(opts, :budget_plan)
    attempt = Keyword.get(opts, :attempt, 1)

    output =
      if provider do
        Runner.run(
          version.question,
          attrs,
          budgeted_provider(provider, budget_plan, version, attempt),
          private_entities: []
        )
      else
        %{plan: [], sources: [], evidence: [], failures: []}
      end

    direct =
      fetch_direct_sources(
        get_in(version.inputs || %{}, ["urls"]) || [],
        budgeted_fetcher(
          Keyword.get(opts, :fetcher, &PublicUrlFetcher.fetch/1),
          budget_plan,
          version,
          attempt
        )
      )

    output
    |> Map.update(:sources, direct.sources, &(&1 ++ direct.sources))
    |> Map.update(:evidence, direct.evidence, &(&1 ++ direct.evidence))
    |> Map.put(:source_failures, direct.failures)
    |> Map.put(:direct_retrieval_calls, direct.calls)
  end

  defp budgeted_provider(provider, nil, _version, _attempt), do: provider

  defp budgeted_provider(provider, budget_plan, version, attempt) do
    fn lane ->
      key =
        ContentHash.digest(%{
          "budget_plan" => budget_plan.content_hash,
          "version" => version.content_hash,
          "attempt" => attempt,
          "lane" => lane.lane,
          "query" => lane.safe_query
        })

      budgeted_retrieval(budget_plan, key, %{"lane" => lane.lane}, fn ->
        if is_function(provider, 1), do: provider.(lane), else: provider.search(lane)
      end)
    end
  end

  defp budgeted_fetcher(fetcher, nil, _version, _attempt), do: fetcher

  defp budgeted_fetcher(fetcher, budget_plan, version, attempt) do
    fn uri ->
      key =
        ContentHash.digest(%{
          "budget_plan" => budget_plan.content_hash,
          "version" => version.content_hash,
          "attempt" => attempt,
          "uri" => uri
        })

      budgeted_retrieval(budget_plan, key, %{"kind" => "direct_source"}, fn ->
        fetcher.(uri)
      end)
    end
  end

  defp budgeted_retrieval(budget_plan, key, metadata, operation) do
    request = %{
      "kind" => "retrieval",
      "max_input_tokens" => 0,
      "max_output_tokens" => 0,
      "idempotency_key" => key,
      "metadata" => metadata
    }

    case BudgetGovernor.reserve(budget_plan, "research", request, on_exhaustion: :fallback) do
      {:ok, reservation} ->
        case operation.() do
          {:ok, _result} = result ->
            case BudgetGovernor.complete(reservation, %{}) do
              {:ok, _completed} -> result
              {:error, _reason} -> {:error, :budget_accounting_failed}
            end

          {:error, _reason} = error ->
            _released = BudgetGovernor.release(reservation, "stop_model_lane")
            error
        end

      {:fallback, _reservation} ->
        {:error, :budget_exhausted}

      {:error, _reason} ->
        {:error, :budget_exhausted}
    end
  end

  defp fetch_direct_sources([], _fetcher),
    do: %{sources: [], evidence: [], failures: [], calls: 0}

  defp fetch_direct_sources(entries, fetcher) do
    entries = Enum.take(entries, 10)

    results =
      entries
      |> Task.async_stream(
        fn entry -> {entry, fetcher.(entry["uri"])} end,
        max_concurrency: @max_direct_concurrency,
        ordered: true,
        timeout: @direct_timeout,
        on_timeout: :kill_task
      )
      |> Enum.to_list()

    {sources, evidence, failures} =
      entries
      |> Enum.zip(results)
      |> Enum.reduce({[], [], []}, fn
        {_entry, {:ok, {fetched_entry, {:ok, fetched}}}}, {sources, evidence, failures} ->
          entry = fetched_entry
          {source, item} = direct_material(entry["uri"], fetched)
          {[source | sources], [item | evidence], failures}

        {_entry, {:ok, {fetched_entry, {:error, reason}}}}, {sources, evidence, failures} ->
          entry = fetched_entry
          failure = direct_failure(entry["uri"], reason)
          {sources, evidence, [failure | failures]}

        {entry, {:exit, _reason}}, {sources, evidence, failures} ->
          failure = direct_failure(entry["uri"], :source_timeout)

          {sources, evidence, [failure | failures]}
      end)

    %{
      sources: Enum.reverse(sources),
      evidence: Enum.reverse(evidence),
      failures: Enum.reverse(failures),
      calls: length(results)
    }
  end

  defp direct_material(uri, fetched) do
    reference = "source:#{digest(uri)}"
    title = fetched.title || URI.parse(uri).host || "Supplied source"
    text = fetched.text || ""

    source = %{
      reference: reference,
      kind: "web",
      title: title,
      uri: fetched.uri || uri,
      content_hash: ContentHash.digest(%{"uri" => uri, "text" => text}),
      parsed_text: text,
      metadata: %{
        "lane" => "supplied_url",
        "lanes" => ["supplied_url"],
        "entry_type" => "user_supplied_url",
        "source_occurrences" => 1
      }
    }

    claim =
      [title, text |> String.replace(~r/\s+/u, " ") |> String.trim() |> String.slice(0, 420)]
      |> Enum.reject(&(&1 in [nil, ""]))
      |> Enum.join(": ")
      |> String.slice(0, 600)

    evidence = %{
      source_reference: reference,
      kind: "research_candidate",
      claim: claim,
      grounding_level: "external_research",
      confidence_score: 0.6,
      tags: ["supplied_url"],
      metadata: %{"provenance" => [%{"source_reference" => reference, "uri" => uri}]}
    }

    {source, evidence}
  end

  defp direct_failure(uri, reason) do
    %{
      source_id: "source-#{String.slice(digest(uri), 0, 16)}",
      reason: normalize_failure(reason)
    }
  end

  defp normalize_failure(reason)
       when reason in [
              :invalid_url,
              :invalid_public_https_url,
              :non_public_host,
              :unsupported_content_type,
              :source_too_large,
              :unavailable_source,
              :unreadable_source,
              :source_timeout
            ],
       do: to_string(reason)

  defp normalize_failure(_reason), do: "unavailable_source"

  defp digest(value) do
    value |> then(&:crypto.hash(:sha256, &1)) |> Base.encode16(case: :lower)
  end

  defp inferred_audience(question) do
    normalized = String.downcase(question)

    cond do
      String.contains?(normalized, ["employee", "employees", "сотрудник", "сотрудники"]) ->
        "employees"

      String.contains?(normalized, ["customer", "customers", "consumer", "клиент"]) ->
        "customers"

      true ->
        "participants"
    end
  end
end
