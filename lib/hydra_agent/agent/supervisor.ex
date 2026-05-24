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
    child_spec = {HydraAgent.Agent.RunWorker, Keyword.put(opts, :run_id, run_id)}
    DynamicSupervisor.start_child(__MODULE__, child_spec)
  end

  def run_worker_pid(run_id) do
    case Registry.lookup(HydraAgent.ProcessRegistry, {:run_worker, run_id}) do
      [{pid, _value}] -> {:ok, pid}
      [] -> {:error, :not_found}
    end
  end

  def stop_run_worker(run_id) do
    with {:ok, pid} <- run_worker_pid(run_id) do
      DynamicSupervisor.terminate_child(__MODULE__, pid)
    end
  end

  @impl true
  def init(_opts) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end
end
