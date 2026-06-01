defmodule HydraAgent.Agent.Supervisor do
  @moduledoc """
  Dynamic supervisor for runtime-owned agent processes.

  V1 keeps the process layer intentionally small: durable run and conversation
  state lives in Postgres, while supervised processes are used for active work.
  """

  use DynamicSupervisor

  def start_link(opts) do
    DynamicSupervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def start_run_worker(run_id, opts \\ []) do
    run_id = normalize_run_id(run_id)
    child_spec = {HydraAgent.Agent.RunWorker, Keyword.put(opts, :run_id, run_id)}
    DynamicSupervisor.start_child(__MODULE__, child_spec)
  end

  def run_worker_pid(run_id) do
    run_id = normalize_run_id(run_id)

    case Registry.lookup(HydraAgent.ProcessRegistry, {:run_worker, run_id}) do
      [{pid, _value}] -> {:ok, pid}
      [] -> {:error, :not_found}
    end
  end

  def run_worker_status(run_id) do
    run_id = normalize_run_id(run_id)

    case run_worker_pid(run_id) do
      {:ok, pid} ->
        active_run_worker_status(run_id, pid)

      {:error, :not_found} ->
        inactive_run_worker_status(run_id)
    end
  end

  def stop_run_worker(run_id) do
    run_id = normalize_run_id(run_id)

    with {:ok, pid} <- run_worker_pid(run_id) do
      DynamicSupervisor.terminate_child(__MODULE__, pid)
    end
  end

  @impl true
  def init(_opts) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end

  defp active_run_worker_status(run_id, pid) do
    process_status = HydraAgent.Agent.RunWorker.status(pid)
    runtime_status = HydraAgent.Runtime.run_worker_summary(run_id, process_status.lease_owner)

    Map.merge(runtime_status, %{
      active: true,
      pid: inspect(pid),
      lease_owner: process_status.lease_owner,
      lease_ms: process_status.lease_ms,
      started_at: process_status.started_at,
      last_heartbeat_at: process_status.last_heartbeat_at
    })
  catch
    :exit, _reason -> inactive_run_worker_status(run_id)
  end

  defp inactive_run_worker_status(run_id) do
    HydraAgent.Runtime.run_worker_summary(run_id, nil)
    |> Map.merge(%{active: false, pid: nil})
  end

  defp normalize_run_id(run_id) when is_integer(run_id), do: run_id

  defp normalize_run_id(run_id) when is_binary(run_id) do
    case Integer.parse(run_id) do
      {integer, ""} -> integer
      _parsed -> run_id
    end
  end

  defp normalize_run_id(run_id), do: run_id
end
