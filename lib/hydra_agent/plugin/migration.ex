defmodule HydraAgent.Plugin.Migration do
  @moduledoc """
  Trusted plugin migration contract.

  Plugin migrations are intentionally explicit and inspectable. Operators should
  dry-run before applying, and implementations must remain workspace-scoped
  unless the manifest and approval explicitly mark the migration global.
  """

  @callback plan(map()) :: {:ok, map()} | {:error, map()}
  @callback run(map()) :: {:ok, map()} | {:error, map()}
end
