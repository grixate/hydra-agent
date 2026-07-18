defmodule HydraAgent.SimLab.Research.WebSearchProvider do
  @moduledoc """
  Provider contract for search, making production retrieval swappable and testable.
  """

  @callback search(%{safe_query: String.t(), region: String.t(), language: String.t()}) ::
              {:ok, [map()]} | {:error, term()}

  @callback search_many([map()]) :: {:ok, %{optional(String.t()) => [map()]}} | {:error, term()}

  @optional_callbacks search_many: 1
end
