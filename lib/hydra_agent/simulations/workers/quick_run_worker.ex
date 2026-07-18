defmodule HydraAgent.Simulations.Workers.QuickRunWorker do
  @moduledoc "Durable Oban boundary for one Quick simulation run."

  use Oban.Worker,
    queue: :simulations,
    max_attempts: 5,
    unique: [
      fields: [:args],
      period: :infinity,
      states: :incomplete
    ]

  alias HydraAgent.Simulations.Engine

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"simulation_run_record_id" => record_id}} = job) do
    case Engine.execute(record_id) do
      {:ok, _record} -> :ok
      {:error, {:terminal_fence, _status}} -> :ok
      {:error, :terminal_fence} -> :ok
      {:error, reason} when job.attempt >= job.max_attempts -> {:cancel, inspect(reason)}
      {:error, reason} -> {:error, reason}
    end
  end
end
