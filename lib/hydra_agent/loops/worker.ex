defmodule HydraAgent.Loops.Worker do
  @moduledoc """
  Periodic governed-loop dispatcher.
  """

  use GenServer

  alias HydraAgent.Loops
  alias HydraAgent.Loops.Engine
  require Logger

  @default_interval_ms 60_000

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(opts) do
    state = %{interval_ms: Keyword.get(opts, :interval_ms, @default_interval_ms)}
    schedule_tick(state.interval_ms)
    {:ok, state}
  end

  @impl true
  def handle_info(:run_due, state) do
    run_due()
    schedule_tick(state.interval_ms)
    {:noreply, state}
  end

  def run_due(now \\ DateTime.utc_now() |> DateTime.truncate(:microsecond)) do
    now
    |> Loops.due_loops()
    |> Enum.map(fn loop ->
      Engine.tick(loop, lease_owner: "loop-worker-#{node()}-#{inspect(self())}")
    end)
  rescue
    error ->
      Logger.warning("loop worker skipped tick: #{Exception.message(error)}")
      []
  end

  defp schedule_tick(interval_ms), do: Process.send_after(self(), :run_due, interval_ms)
end
