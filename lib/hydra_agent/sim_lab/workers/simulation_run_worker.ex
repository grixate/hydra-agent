defmodule HydraAgent.SimLab.Workers.SimulationRunWorker do
  @moduledoc """
  Durable execution boundary for deterministic aggregate simulations.

  Oban stores only the simulation run identifier. The compiled, source-safe
  input snapshot and execution options live on the run itself.
  """

  use Oban.Worker,
    queue: :sim_lab,
    max_attempts: 3,
    unique: [fields: [:args], period: :infinity]

  alias HydraAgent.SimLab.Simulations

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"run_id" => run_id}} = job) do
    try do
      perform_run(job, run_id)
    rescue
      error -> terminal_error(job, run_id, Exception.message(error))
    end
  end

  defp perform_run(job, run_id) do
    case Simulations.execute_queued_run(run_id) do
      {:ok, _result} -> :ok
      :ok -> :ok
      {:error, reason} -> terminal_error(job, run_id, inspect(reason))
    end
  end

  defp terminal_error(%Oban.Job{attempt: attempt, max_attempts: max_attempts}, run_id, reason)
       when attempt >= max_attempts do
    case Simulations.fail_run(run_id) do
      :ok -> {:cancel, reason}
      {:error, _changeset} -> {:error, reason}
    end
  end

  defp terminal_error(_job, _run_id, reason), do: {:error, reason}
end
