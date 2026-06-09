defmodule HydraAgent.Plugin.Tool do
  @moduledoc """
  Trusted in-release plugin tool callback contract.
  """

  @callback spec() :: map()
  @callback execute(map(), map()) :: {:ok, map()} | {:error, map()}
end
