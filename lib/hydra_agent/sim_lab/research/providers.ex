defmodule HydraAgent.SimLab.Research.Providers do
  @moduledoc """
  Provider selection at the SimLab product boundary.

  Retrieval and model generation stay separate: Tavily (or a generic search
  endpoint) supplies attributable web sources, while the Codex CLI adapter is
  an explicit local test-hypothesis mode. Future model adapters can be added
  without changing the research runner or persisted provenance format.
  """

  alias HydraAgent.SimLab.Research.{
    ConfiguredWebSearchProvider,
    TavilyWebSearchProvider
  }

  def web_search do
    if TavilyWebSearchProvider.configured?(),
      do: TavilyWebSearchProvider,
      else: ConfiguredWebSearchProvider
  end

  def web_search_configured? do
    TavilyWebSearchProvider.configured?() or ConfiguredWebSearchProvider.configured?()
  end
end
