defmodule HydraAgent.Plugin.Connector do
  @moduledoc """
  Trusted in-release connector callback contract.
  """

  @callback spec() :: map()
  @callback execute_action(map(), map()) :: {:ok, map()} | {:error, map()}
end
