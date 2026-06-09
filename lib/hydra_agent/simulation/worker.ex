defmodule HydraAgent.Simulation.Worker do
  @moduledoc """
  Supervised active execution process for one simulation.
  """

  use GenServer

  alias HydraAgent.Simulation
  alias HydraAgent.Simulation.Engine.Runner

  @heartbeat_interval_ms 10_000

  def child_spec(opts) do
    simulation_id = Keyword.fetch!(opts, :simulation_id)

    %{
      id: {__MODULE__, simulation_id},
      start: {__MODULE__, :start_link, [opts]},
      restart: :temporary
    }
  end

  def start_link(opts) do
    simulation_id = Keyword.fetch!(opts, :simulation_id)

    GenServer.start_link(__MODULE__, opts,
      name: {:via, Registry, {HydraAgent.ProcessRegistry, {:simulation_worker, simulation_id}}}
    )
  end

  def status(pid) when is_pid(pid), do: GenServer.call(pid, :status)

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)

    state = %{
      simulation_id: Keyword.fetch!(opts, :simulation_id),
      lease_id: Keyword.get(opts, :lease_id),
      started_at: now(),
      last_heartbeat_at: now(),
      task: nil,
      opts: opts
    }

    {:ok, state, {:continue, :run}}
  end

  @impl true
  def handle_call(:status, _from, state) do
    {:reply,
     %{
       simulation_id: state.simulation_id,
       lease_id: state.lease_id,
       started_at: state.started_at,
       last_heartbeat_at: state.last_heartbeat_at,
       task_pid: task_pid(state.task)
     }, state}
  end

  @impl true
  def handle_continue(:run, state) do
    state = %{state | last_heartbeat_at: now()}
    schedule_heartbeat()
    task = Task.Supervisor.async_nolink(HydraAgent.TaskSupervisor, fn -> run(state) end)
    {:noreply, %{state | task: task}}
  end

  @impl true
  def handle_info({ref, result}, %{task: %{ref: ref}} = state) do
    Process.demonitor(ref, [:flush])
    maybe_mark_failed(result, state)
    {:stop, :normal, %{state | task: nil, last_heartbeat_at: now()}}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{task: %{ref: ref}} = state) do
    maybe_mark_failed({:exit, reason}, state)
    {:stop, :normal, %{state | task: nil, last_heartbeat_at: now()}}
  end

  def handle_info(:heartbeat, state) do
    if state.lease_id do
      Simulation.heartbeat_simulation(state.simulation_id, state.lease_id)
    end

    schedule_heartbeat()
    {:noreply, %{state | last_heartbeat_at: now()}}
  end

  @impl true
  def terminate(_reason, %{task: nil}), do: :ok

  def terminate(_reason, %{task: task}) do
    Task.shutdown(task, :brutal_kill)
    :ok
  end

  defp run(state) do
    opts = Keyword.drop(state.opts, [:simulation_id])
    runner_fn = Keyword.get(opts, :runner_fn, &Runner.run/2)
    runner_fn.(state.simulation_id, Keyword.drop(opts, [:runner_fn]))
  end

  defp maybe_mark_failed({:error, reason}, state), do: fail(state, reason)
  defp maybe_mark_failed({:exit, :normal}, _state), do: :ok
  defp maybe_mark_failed({:exit, :shutdown}, _state), do: :ok
  defp maybe_mark_failed({:exit, {:shutdown, _reason}}, _state), do: :ok
  defp maybe_mark_failed({:exit, reason}, state), do: fail(state, reason)
  defp maybe_mark_failed(_result, _state), do: :ok

  defp fail(state, reason) do
    state.simulation_id
    |> Simulation.get_simulation!()
    |> Simulation.fail_simulation(reason)

    :ok
  rescue
    _error -> :ok
  end

  defp task_pid(nil), do: nil
  defp task_pid(%Task{pid: pid}), do: inspect(pid)

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:microsecond)

  defp schedule_heartbeat, do: Process.send_after(self(), :heartbeat, @heartbeat_interval_ms)
end
