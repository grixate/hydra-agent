defmodule HydraAgent.Simulations.Engine do
  @moduledoc "Public execution boundary for per-run simulation supervision."

  alias HydraAgent.Simulations.Engine.{RunCoordinator, RunStore, Supervisor}

  def execute(record_id, opts \\ []) do
    record = RunStore.get_record!(record_id)

    case Supervisor.start_run(record, opts) do
      {:ok, _pid} -> await_and_stop(record.id)
      {:error, {:already_started, _pid}} -> await_and_stop(record.id)
      {:error, reason} -> {:error, reason}
    end
  end

  def stop(record_id), do: Supervisor.stop_run(record_id)

  defp await_and_stop(record_id) do
    result = await_with_restart(record_id, 5)
    _stopped = Supervisor.stop_run(record_id)
    result
  end

  defp await_with_restart(_record_id, 0), do: {:error, :coordinator_unavailable}

  defp await_with_restart(record_id, attempts) do
    RunCoordinator.await(record_id, :infinity)
  catch
    :exit, _reason ->
      Process.sleep(20)
      await_with_restart(record_id, attempts - 1)
  end
end
