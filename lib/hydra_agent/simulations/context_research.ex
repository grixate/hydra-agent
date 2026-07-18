defmodule HydraAgent.Simulations.ContextResearch do
  @moduledoc "Runs the existing bounded retrieval pipeline for a Simulation Version."

  alias HydraAgent.SimLab.Research.{PublicUrlFetcher, Runner}
  alias HydraAgent.Simulations.ContentHash
  alias HydraAgent.Simulations.SimulationVersion

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

    output =
      if provider do
        Runner.run(version.question, attrs, provider, private_entities: [])
      else
        %{plan: [], sources: [], evidence: [], failures: []}
      end

    direct =
      fetch_direct_sources(
        get_in(version.inputs || %{}, ["urls"]) || [],
        Keyword.get(opts, :fetcher, &PublicUrlFetcher.fetch/1)
      )

    output
    |> Map.update(:sources, direct.sources, &(&1 ++ direct.sources))
    |> Map.update(:evidence, direct.evidence, &(&1 ++ direct.evidence))
    |> Map.put(:source_failures, direct.failures)
    |> Map.put(:direct_retrieval_calls, direct.calls)
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
