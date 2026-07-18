defmodule HydraAgent.Simulations.Engine.RunSupervisor do
  @moduledoc "Per-run supervision tree for deterministic simulation work."
  use Supervisor

  alias HydraAgent.Simulations.Engine.{
    EventRecorder,
    ResourceLedger,
    RunCoordinator,
    Snapshotter,
    StateStoreSupervisor
  }

  def start_link(opts) do
    record_id = Keyword.fetch!(opts, :run_record_id)
    Supervisor.start_link(__MODULE__, opts, name: name(record_id))
  end

  def name(record_id),
    do: {:via, Registry, {HydraAgent.ProcessRegistry, {:simulation_run_supervisor, record_id}}}

  @impl true
  def init(opts) do
    record_id = Keyword.fetch!(opts, :run_record_id)
    partition_count = Keyword.fetch!(opts, :partition_count)

    children = [
      {StateStoreSupervisor, run_record_id: record_id, partition_count: partition_count},
      {ResourceLedger, run_record_id: record_id},
      {EventRecorder, run_record_id: record_id},
      {Snapshotter, run_record_id: record_id},
      {RunCoordinator, opts}
    ]

    Supervisor.init(children, strategy: :rest_for_one)
  end
end
