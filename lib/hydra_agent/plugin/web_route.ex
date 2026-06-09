defmodule HydraAgent.Plugin.WebRoute do
  @moduledoc """
  Trusted web route plugin contract.
  """

  @callback routes() :: list(map())
end
