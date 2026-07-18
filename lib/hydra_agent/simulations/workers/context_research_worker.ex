defmodule HydraAgent.Simulations.Workers.ContextResearchWorker do
  @moduledoc "Durable bounded retrieval for one immutable Simulation Version."

  use Oban.Worker,
    queue: :research,
    max_attempts: 3,
    unique: [fields: [:args], period: :infinity]

  import Ecto.Query

  alias HydraAgent.{Repo, Simulations}
  alias HydraAgent.SimLab.Research.{MockWebSearchProvider, Providers}
  alias HydraAgent.Simulations.{ContextResearch, ContextResearchRun, SimulationVersion}

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"context_research_run_id" => id}} = job) do
    with %ContextResearchRun{} = run <- Repo.get(ContextResearchRun, id),
         %SimulationVersion{} = version <- Repo.get(SimulationVersion, run.simulation_version_id) do
      case claim(run) do
        {:ok, :finished} -> :ok
        {:ok, claimed} -> execute(job, claimed, version)
        {:error, reason} -> {:error, inspect(reason)}
      end
    else
      nil -> {:discard, "context research run or Simulation Version no longer exists"}
    end
  rescue
    error -> retry_or_fail(job, id, Exception.message(error))
  end

  defp claim(run) do
    Repo.transaction(fn ->
      current =
        ContextResearchRun
        |> where([candidate], candidate.id == ^run.id)
        |> lock("FOR UPDATE")
        |> Repo.one!()

      if current.status in ["completed", "cancelled"] do
        :finished
      else
        current
        |> ContextResearchRun.changeset(%{
          status: "running",
          started_at: current.started_at || DateTime.utc_now(),
          completed_at: nil,
          failure_reason: nil
        })
        |> Repo.update!()
      end
    end)
  end

  defp execute(job, run, version) do
    output = ContextResearch.run(version, provider(run.provider))

    case Simulations.complete_context_research(run, output) do
      {:ok, _result} -> :ok
      {:error, reason} -> retry_or_fail(job, run.id, inspect(reason))
    end
  end

  defp retry_or_fail(%Oban.Job{attempt: attempt, max_attempts: max}, id, reason)
       when attempt >= max do
    if run = Repo.get(ContextResearchRun, id) do
      Simulations.fail_context_research(run, sanitize_reason(reason))
    end

    {:cancel, sanitize_reason(reason)}
  end

  defp retry_or_fail(_job, _id, reason), do: {:error, sanitize_reason(reason)}

  defp provider("web_search"), do: Providers.web_search()
  defp provider("direct_sources"), do: nil
  defp provider("mock"), do: MockWebSearchProvider

  defp sanitize_reason(reason) do
    reason
    |> to_string()
    |> String.replace(~r/[\r\n\t]+/u, " ")
    |> String.slice(0, 1_000)
  end
end
