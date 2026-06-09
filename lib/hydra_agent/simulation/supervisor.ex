defmodule HydraAgent.Simulation.Supervisor do
  @moduledoc """
  Dynamic supervisor for active simulation workers.

  Durable simulation state lives in Postgres. The supervised worker is only the
  active execution process for a running simulation.
  """

  use DynamicSupervisor

  def start_link(opts) do
    DynamicSupervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def start_worker(simulation_id, opts \\ []) do
    simulation_id = normalize_id(simulation_id)
    child_spec = {HydraAgent.Simulation.Worker, Keyword.put(opts, :simulation_id, simulation_id)}
    DynamicSupervisor.start_child(__MODULE__, child_spec)
  end

  def worker_pid(simulation_id) do
    simulation_id = normalize_id(simulation_id)

    case Registry.lookup(HydraAgent.ProcessRegistry, {:simulation_worker, simulation_id}) do
      [{pid, _value}] -> {:ok, pid}
      [] -> {:error, :not_found}
    end
  end

  def worker_status(simulation_id) do
    simulation_id = normalize_id(simulation_id)

    case worker_pid(simulation_id) do
      {:ok, pid} ->
        HydraAgent.Simulation.Worker.status(pid)
        |> Map.merge(%{active: true, pid: inspect(pid)})

      {:error, :not_found} ->
        %{simulation_id: simulation_id, active: false, pid: nil}
    end
  catch
    :exit, _reason -> %{simulation_id: simulation_id, active: false, pid: nil}
  end

  def stop_worker(simulation_id) do
    simulation_id = normalize_id(simulation_id)

    with {:ok, pid} <- worker_pid(simulation_id) do
      DynamicSupervisor.terminate_child(__MODULE__, pid)
    end
  end

  @impl true
  def init(_opts) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end

  defp normalize_id(id) when is_integer(id), do: id

  defp normalize_id(id) when is_binary(id) do
    case Integer.parse(id) do
      {integer, ""} -> integer
      _parsed -> id
    end
  end

  defp normalize_id(id), do: id
end
