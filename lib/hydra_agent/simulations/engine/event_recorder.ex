defmodule HydraAgent.Simulations.Engine.EventRecorder do
  @moduledoc "Assigns deterministic event order without depending on scheduler order."
  use GenServer

  alias HydraAgent.Simulations.ContentHash

  @phase_order %{
    "prepare" => 0,
    "before_actions" => 10,
    "actions" => 20,
    "after_actions" => 30,
    "transitions" => 40,
    "observations" => 50,
    "snapshot" => 60,
    "complete" => 70,
    "failed" => 80
  }

  def start_link(opts) do
    run_record_id = Keyword.fetch!(opts, :run_record_id)
    sequence = Keyword.get(opts, :sequence, 0)
    GenServer.start_link(__MODULE__, sequence, name: name(run_record_id))
  end

  def name(run_record_id),
    do:
      {:via, Registry, {HydraAgent.ProcessRegistry, {:simulation_event_recorder, run_record_id}}}

  def reset(run_record_id, sequence),
    do: GenServer.call(name(run_record_id), {:reset, sequence})

  def prepare(run_record_id, pack_hash, round, events),
    do: GenServer.call(name(run_record_id), {:prepare, pack_hash, round, events}, :infinity)

  def commit(run_record_id, sequence),
    do: GenServer.call(name(run_record_id), {:commit, sequence})

  @impl true
  def init(sequence), do: {:ok, %{sequence: sequence}}

  @impl true
  def handle_call({:reset, sequence}, _from, state),
    do: {:reply, :ok, %{state | sequence: sequence}}

  def handle_call({:prepare, pack_hash, round, events}, _from, state) do
    ordered =
      events
      |> Enum.with_index()
      |> Enum.sort_by(fn {event, index} ->
        {
          Map.get(@phase_order, event.phase, 999),
          Map.get(event, :priority, 0),
          event.type,
          event.actor_key || "",
          event.source_ref || "",
          index
        }
      end)
      |> Enum.with_index(state.sequence + 1)
      |> Enum.map(fn {{event, stable_index}, sequence} ->
        idempotency_key =
          ContentHash.digest(%{
            "pack" => pack_hash,
            "round" => round,
            "phase" => event.phase,
            "type" => event.type,
            "actor" => event.actor_key,
            "source" => event.source_ref,
            "index" => stable_index
          })

        event
        |> Map.from_struct()
        |> Map.drop([:priority])
        |> Map.merge(%{
          sequence: sequence,
          round: round,
          idempotency_key: idempotency_key
        })
      end)

    next_sequence = if ordered == [], do: state.sequence, else: List.last(ordered).sequence
    {:reply, {ordered, next_sequence}, state}
  end

  def handle_call({:commit, sequence}, _from, state),
    do: {:reply, :ok, %{state | sequence: sequence}}

  defmodule Event do
    @moduledoc false
    defstruct type: nil,
              phase: nil,
              summary: nil,
              actor_key: nil,
              targets: [],
              payload: %{},
              source_ref: nil,
              provenance: %{},
              priority: 0
  end
end
