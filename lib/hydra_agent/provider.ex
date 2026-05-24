defmodule HydraAgent.Provider do
  @moduledoc """
  Behaviour for model providers.

  Providers receive a `HydraAgent.Runtime.ProviderConfig` and a normalized
  request map. Adapters must return structured maps and avoid raising for
  provider/API failures so the runtime can persist useful recovery context.
  """

  @callback chat(struct(), map()) :: {:ok, map()} | {:error, map()}
  @callback stream_chat(struct(), map(), (map() -> any())) :: {:ok, map()} | {:error, map()}
  @callback embed(struct(), map()) :: {:ok, map()} | {:error, map()}
  @callback models(struct()) :: {:ok, list(map())} | {:error, map()}
  @callback health(struct()) :: :ok | {:error, map()}
end
