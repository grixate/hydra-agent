defmodule HydraAgent.Plugin.RoomChannel do
  @moduledoc """
  Trusted in-release room channel callback contract.
  """

  @callback spec() :: map()
  @callback deliver(map(), map()) :: {:ok, map()} | {:error, map()}
end
