defmodule HydraAgent.Simulations.Engine.StateStoreSupervisor do
  @moduledoc "Stable, bounded state partitions for one active run."
  use Supervisor

  alias HydraAgent.Simulations.Engine.StatePartition

  def start_link(opts), do: Supervisor.start_link(__MODULE__, opts)

  @impl true
  def init(opts) do
    run_record_id = Keyword.fetch!(opts, :run_record_id)
    partition_count = Keyword.fetch!(opts, :partition_count)

    children =
      Enum.map(0..(partition_count - 1), fn index ->
        Supervisor.child_spec(
          {StatePartition, run_record_id: run_record_id, index: index},
          id: {:state_partition, index}
        )
      end)

    Supervisor.init(children, strategy: :one_for_one)
  end

  def load(run_record_id, agents, partition_count) do
    grouped = Enum.group_by(agents, &partition_for(&1["id"], partition_count))

    Enum.each(0..(partition_count - 1), fn index ->
      StatePartition.put(run_record_id, index, Map.get(grouped, index, []))
    end)

    :ok
  end

  def agents(run_record_id, partition_count) do
    0..(partition_count - 1)
    |> Enum.flat_map(&StatePartition.all(run_record_id, &1))
    |> Enum.sort_by(& &1["id"])
  end

  def partition_for(agent_id, count) do
    <<value::unsigned-integer-size(64), _rest::binary>> = :crypto.hash(:sha256, agent_id)
    rem(value, count)
  end
end
