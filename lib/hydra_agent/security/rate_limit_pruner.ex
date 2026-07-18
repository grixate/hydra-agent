defmodule HydraAgent.Security.RateLimitPruner do
  @moduledoc false
  use GenServer

  require Logger

  @interval :timer.hours(1)

  def start_link(_opts), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

  @impl GenServer
  def init(:ok) do
    schedule()
    {:ok, %{}}
  end

  @impl GenServer
  def handle_info(:prune, state) do
    case HydraAgent.Security.RateLimiter.prune_expired() do
      {:ok, _result} -> :ok
      {:error, reason} -> Logger.warning("request rate-limit pruning failed: #{inspect(reason)}")
    end

    schedule()
    {:noreply, state}
  end

  defp schedule, do: Process.send_after(self(), :prune, @interval)
end
