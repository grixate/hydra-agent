defmodule HydraAgent.Simulations.ContextResearchTest do
  use ExUnit.Case, async: true

  alias HydraAgent.Simulations.{ContextBuilder, ContextResearch, SimulationVersion}

  test "supplied URLs are fetched through the bounded direct-source path without search credentials" do
    version = version(["https://source.example/ok", "https://source.example/unavailable"])

    fetcher = fn
      "https://source.example/ok" ->
        {:ok,
         %{
           uri: "https://source.example/ok",
           title: "Operational study",
           text: "Observed teams adopted gradually when the new routine preserved local control."
         }}

      "https://source.example/unavailable" ->
        {:error, :unavailable_source}
    end

    output = ContextResearch.run(version, nil, fetcher: fetcher)

    assert output.plan == []
    assert output.direct_retrieval_calls == 2
    assert length(output.sources) == 1
    assert length(output.evidence) == 1
    assert [%{reason: "unavailable_source"}] = output.source_failures

    assert {:ok, pack} = ContextBuilder.build(version, research_output: output)
    assert pack["status"] == "partial"
    assert pack["research_metadata"]["provider_calls"] == 2
    assert pack["research_metadata"]["failed_source_count"] == 1

    assert Enum.any?(pack["sources"], fn source ->
             source["uri"] == "https://source.example/ok" and
               source["status"] == "active" and
               source["title"] == "Operational study"
           end)

    assert Enum.any?(pack["sources"], fn source ->
             source["uri"] == "https://source.example/unavailable" and
               source["status"] == "pending"
           end)

    assert Enum.any?(pack["claims"], fn claim ->
             claim["grounding_class"] == "external_source" and
               String.contains?(claim["statement"], "adopted gradually")
           end)

    assert Enum.any?(pack["gaps"], &(&1["kind"] == "source_retrieval_failed"))
  end

  defp version(urls) do
    entries = Enum.map(urls, &%{"uri" => &1, "status" => "pending"})

    %SimulationVersion{
      question: "How might teams adopt a new coordination practice?",
      locale: "en",
      normalized_input: %{
        "question" => "How might teams adopt a new coordination practice?",
        "geography" => nil,
        "horizon" => nil,
        "historical_cutoff" => nil,
        "source_counts" => %{"files" => 0, "notes" => 0, "urls" => length(entries)}
      },
      inputs: %{"notes" => nil, "urls" => entries, "files" => []},
      research_settings: %{"preset" => "quick"},
      population_size: 5_000
    }
  end
end
