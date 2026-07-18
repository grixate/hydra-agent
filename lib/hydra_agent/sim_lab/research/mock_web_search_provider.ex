defmodule HydraAgent.SimLab.Research.MockWebSearchProvider do
  @moduledoc """
  Deterministic research provider for demos and integration tests.
  """

  @behaviour HydraAgent.SimLab.Research.WebSearchProvider

  @impl true
  def search(%{safe_query: safe_query, region: region, language: language}) do
    {:ok,
     [
       %{
         title: "Research result for #{safe_query}",
         url: "https://example.test/research/#{:erlang.phash2(safe_query)}",
         snippet:
           "Mocked evidence candidate; it is clearly marked until a production source provider is configured.",
         region: region,
         language: language,
         reliability: "unknown"
       }
     ]}
  end
end
