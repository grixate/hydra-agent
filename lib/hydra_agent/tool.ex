defmodule HydraAgent.Tool do
  @moduledoc """
  Contract for runtime tools.

  Tools are intentionally small and explicit: each one declares its name,
  side-effect class, input/output schemas, timeout, and approval sensitivity
  before the runner may execute it.
  """

  @callback spec() :: map()
  @callback execute(map(), map()) :: {:ok, map()} | {:error, map()}
end
