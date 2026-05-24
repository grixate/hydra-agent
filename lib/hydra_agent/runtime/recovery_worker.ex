defmodule HydraAgent.Runtime.RecoveryWorker do
  @moduledoc """
  Periodically recovers expired run-step leases.

  This worker gives Hydra a small but important OTP advantage: stalled workers
  do not require a manual API call before their durable steps can be retried or
  marked failed.
  """

  use GenServer

  alias HydraAgent.Runtime
  require Logger

  @default_interval_ms 30_000
  @default_max_attempts 3

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(opts) do
    state = %{
      interval_ms: Keyword.get(opts, :interval_ms, @default_interval_ms),
      max_attempts: Keyword.get(opts, :max_attempts, @default_max_attempts)
    }

    schedule_tick(state.interval_ms)
    {:ok, state}
  end

  @impl true
  def handle_info(:recover, state) do
    recover(state)
    schedule_tick(state.interval_ms)
    {:noreply, state}
  end

  def recover(state \\ %{max_attempts: @default_max_attempts}) do
    Runtime.list_workspace_ids()
    |> Enum.flat_map(fn workspace_id ->
      Runtime.recover_stale_steps(workspace_id, max_attempts: state.max_attempts)
    end)
  rescue
    error ->
      Logger.warning("runtime recovery worker skipped tick: #{Exception.message(error)}")
      []
  end

  defp schedule_tick(interval_ms), do: Process.send_after(self(), :recover, interval_ms)
end
