defmodule HydraAgent.Simulation.Reconciler do
  @moduledoc """
  Periodically reconciles durable running simulations with active workers.
  """

  use GenServer

  alias HydraAgent.Simulation

  @interval_ms 30_000

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(opts) do
    if Keyword.get(opts, :enabled, true) do
      send(self(), :recover)
    end

    {:ok, opts}
  end

  @impl true
  def handle_info(:recover, opts) do
    Simulation.recover_running_simulations()
    schedule()
    {:noreply, opts}
  end

  defp schedule, do: Process.send_after(self(), :recover, @interval_ms)
end
