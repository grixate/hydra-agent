defmodule HydraAgent.Simulations.Engine.Supervisor do
  @moduledoc "Dynamic owner for active per-run simulation supervisors."
  use DynamicSupervisor

  alias HydraAgent.Simulations.Engine.RunSupervisor

  def start_link(opts), do: DynamicSupervisor.start_link(__MODULE__, opts, name: __MODULE__)

  def start_run(record, opts \\ []) do
    child_opts =
      opts
      |> Keyword.put(:run_record_id, record.id)
      |> Keyword.put(:partition_count, record.partition_count)

    DynamicSupervisor.start_child(__MODULE__, {RunSupervisor, child_opts})
  end

  def stop_run(record_id) do
    case Registry.lookup(HydraAgent.ProcessRegistry, {:simulation_run_supervisor, record_id}) do
      [{pid, _value}] -> DynamicSupervisor.terminate_child(__MODULE__, pid)
      [] -> {:error, :not_found}
    end
  end

  @impl true
  def init(_opts), do: DynamicSupervisor.init(strategy: :one_for_one)
end
