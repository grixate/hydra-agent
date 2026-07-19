defmodule HydraAgent.Simulations.Workers.ReportGenerationWorker do
  @moduledoc "Durable at-most-once provider boundary for one Analysis Report attempt."

  use Oban.Worker,
    queue: :simulations,
    max_attempts: 2,
    unique: [fields: [:args], period: :infinity, states: :incomplete]

  alias HydraAgent.Simulations.ReportGenerator

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"simulation_report_id" => report_id}, attempt: attempt}) do
    case ReportGenerator.generate(report_id, attempt) do
      :ok -> :ok
      {:ok, _report} -> :ok
      {:error, {:report_failed, _report_id}} -> :ok
      {:error, reason} when attempt >= 2 -> {:cancel, inspect(reason)}
      {:error, reason} -> {:error, reason}
    end
  end
end
