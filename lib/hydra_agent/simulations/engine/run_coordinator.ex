defmodule HydraAgent.Simulations.Engine.RunCoordinator do
  @moduledoc "Coordinates one durable Quick run under its per-run supervisor."
  use GenServer

  require Logger

  alias HydraAgent.Simulations.Engine.{QuickEngine, RunStore, StateStoreSupervisor}

  def start_link(opts) do
    record_id = Keyword.fetch!(opts, :run_record_id)
    GenServer.start_link(__MODULE__, opts, name: name(record_id))
  end

  def name(record_id),
    do: {:via, Registry, {HydraAgent.ProcessRegistry, {:simulation_run_coordinator, record_id}}}

  def await(record_id, timeout \\ :infinity),
    do: GenServer.call(name(record_id), :await, timeout)

  @impl true
  def init(opts) do
    {:ok,
     %{
       record_id: Keyword.fetch!(opts, :run_record_id),
       round_delay_ms: Keyword.get(opts, :round_delay_ms, 0),
       pause_after_round: Keyword.get(opts, :pause_after_round),
       notify_pid: Keyword.get(opts, :notify_pid),
       result: nil
     }, {:continue, :execute}}
  end

  @impl true
  def handle_continue(:execute, state) do
    result =
      try do
        execute(state)
      rescue
        error ->
          Logger.error("quick simulation coordinator stopped safely: #{Exception.message(error)}")
          _failure = RunStore.fail(state.record_id, {:coordinator_exception, error.__struct__})
          {:error, :coordinator_exception}
      catch
        kind, reason ->
          Logger.error("quick simulation coordinator stopped safely: #{inspect({kind, reason})}")
          _failure = RunStore.fail(state.record_id, {:coordinator_exit, kind})
          {:error, :coordinator_exit}
      end

    {:noreply, %{state | result: result}}
  end

  @impl true
  def handle_call(:await, _from, %{result: nil} = state),
    do: {:reply, {:error, :not_finished}, state}

  def handle_call(:await, _from, state), do: {:reply, state.result, state}

  defp execute(state) do
    record = RunStore.get_record!(state.record_id)

    cond do
      record.run.status == "completed" ->
        {:ok, record}

      record.run.status in ["failed", "canceled"] ->
        {:error, {:terminal_fence, record.run.status}}

      true ->
        case RunStore.load_or_initialize(record) do
          {:ok, simulation_state, _mode} -> run_rounds(record, simulation_state, state)
          {:error, reason} -> fail(record, reason)
        end
    end
  end

  defp run_rounds(record, simulation_state, coordinator_state) do
    next_round = simulation_state["round"] + 1

    cond do
      not RunStore.runnable?(record.id) ->
        {:error, :terminal_fence}

      simulation_state["stop_reason"] || next_round > record.rounds_planned ->
        RunStore.complete(record, simulation_state)

      true ->
        maybe_delay(coordinator_state.round_delay_ms)

        case QuickEngine.run_round(
               record.id,
               simulation_state,
               record.simulation_script.script,
               next_round,
               record.seed
             ) do
          {:ok, round_result} ->
            :ok =
              StateStoreSupervisor.load(
                record.id,
                round_result.state["agents"],
                record.partition_count
              )

            case RunStore.persist_round(
                   record,
                   round_result.state,
                   round_result.events,
                   round_result.transactions
                 ) do
              {:ok, :committed} ->
                maybe_pause(round_result.state["round"], coordinator_state)
                run_rounds(record, round_result.state, coordinator_state)

              {:ok, :already_committed} ->
                refreshed = RunStore.get_record!(record.id)

                case RunStore.load_or_initialize(refreshed) do
                  {:ok, latest, _mode} -> run_rounds(refreshed, latest, coordinator_state)
                  {:error, reason} -> fail(refreshed, reason)
                end

              {:error, {:terminal_fence, _status} = reason} ->
                {:error, reason}

              {:error, reason} ->
                fail(record, reason)
            end

          {:error, reason} ->
            fail(record, reason)
        end
    end
  end

  defp fail(record, reason) do
    _result = RunStore.fail(record.id, reason)
    {:error, reason}
  end

  defp maybe_delay(0), do: :ok
  defp maybe_delay(milliseconds), do: Process.sleep(milliseconds)

  defp maybe_pause(round, %{pause_after_round: round, notify_pid: notify_pid})
       when is_pid(notify_pid) do
    send(notify_pid, {:simulation_round_committed, self(), round})

    receive do
      {:continue_simulation, ^round} -> :ok
    end
  end

  defp maybe_pause(_round, _state), do: :ok
end
