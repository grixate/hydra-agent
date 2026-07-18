defmodule HydraAgent.Simulations.Engine.StatePartition do
  @moduledoc false
  use GenServer

  def start_link(opts) do
    run_record_id = Keyword.fetch!(opts, :run_record_id)
    index = Keyword.fetch!(opts, :index)
    GenServer.start_link(__MODULE__, %{}, name: name(run_record_id, index))
  end

  def name(run_record_id, index),
    do:
      {:via, Registry,
       {HydraAgent.ProcessRegistry, {:simulation_state_partition, run_record_id, index}}}

  def put(run_record_id, index, agents),
    do: GenServer.call(name(run_record_id, index), {:put, agents}, :infinity)

  def all(run_record_id, index),
    do: GenServer.call(name(run_record_id, index), :all, :infinity)

  @impl true
  def init(_state), do: {:ok, %{}}

  @impl true
  def handle_call({:put, agents}, _from, _state) do
    state = Map.new(agents, &{&1["id"], &1})
    {:reply, :ok, state}
  end

  def handle_call(:all, _from, state), do: {:reply, Map.values(state), state}
end
