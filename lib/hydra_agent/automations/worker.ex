defmodule HydraAgent.Automations.Worker do
  @moduledoc """
  Periodic automation dispatcher.
  """

  use GenServer

  alias HydraAgent.Automations
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

  def run_due do
    Automations.run_due_automations()
  rescue
    error ->
      Logger.warning("automation worker skipped tick: #{Exception.message(error)}")
      []
  end

  defp schedule_tick(interval_ms), do: Process.send_after(self(), :run_due, interval_ms)
end
