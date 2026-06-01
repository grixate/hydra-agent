defmodule HydraAgent.Agent.RunWorker do
  @moduledoc """
  Supervised worker for active run execution.

  The worker is intentionally thin: it leases one durable step at a time, lets
  the runner execute it, and stops cleanly whenever human approval, policy
  blocks, or failures require operator attention.
  """

  use GenServer

  alias HydraAgent.Runtime
  alias HydraAgent.Runtime.Runner

  def child_spec(opts) do
    run_id = Keyword.fetch!(opts, :run_id)

    %{
      id: {__MODULE__, run_id},
      start: {__MODULE__, :start_link, [opts]},
      restart: :temporary
    }
  end

  def start_link(opts) do
    run_id = Keyword.fetch!(opts, :run_id)

    GenServer.start_link(__MODULE__, opts,
      name: {:via, Registry, {HydraAgent.ProcessRegistry, {:run_worker, run_id}}}
    )
  end

  def status(pid) when is_pid(pid) do
    GenServer.call(pid, :status)
  end

  @impl true
  def init(opts) do
    run_id = Keyword.fetch!(opts, :run_id)

    state = %{
      run_id: run_id,
      lease_owner: "run-worker:#{node()}:#{run_id}:#{System.unique_integer([:positive])}",
      lease_ms: Keyword.get(opts, :lease_ms, 60_000),
      auto_complete?: Keyword.get(opts, :auto_complete?, true),
      started_at: now(),
      last_heartbeat_at: now()
    }

    {:ok, state, {:continue, :execute}}
  end

  @impl true
  def handle_call(:status, _from, state) do
    {:reply,
     %{
       run_id: state.run_id,
       lease_owner: state.lease_owner,
       lease_ms: state.lease_ms,
       auto_complete?: state.auto_complete?,
       started_at: state.started_at,
       last_heartbeat_at: state.last_heartbeat_at
     }, state}
  end

  @impl true
  def handle_continue(:execute, state) do
    run = Runtime.get_run!(state.run_id)
    state = %{state | last_heartbeat_at: now()}

    case Runner.execute_next_step(run, lease_owner: state.lease_owner, lease_ms: state.lease_ms) do
      {:ok, :no_planned_steps} ->
        maybe_complete_run(run, state)

      {:ok, _step} ->
        {:noreply, state, {:continue, :execute}}

      {:approval_required, _step} ->
        {:stop, :normal, state}

      {:blocked, _step} ->
        {:stop, :normal, state}

      {:error, _reason_or_step} ->
        {:stop, :normal, state}
    end
  end

  defp maybe_complete_run(run, %{auto_complete?: true} = state) do
    counts = Runtime.step_status_counts(run.id)

    if map_size(counts) > 0 and Map.get(counts, "completed", 0) == Enum.sum(Map.values(counts)) do
      Runtime.complete_run(run, %{
        "result" => %{"completed_steps" => Map.get(counts, "completed", 0)}
      })
    end

    {:stop, :normal, state}
  end

  defp maybe_complete_run(_run, state), do: {:stop, :normal, state}

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:microsecond)
end
