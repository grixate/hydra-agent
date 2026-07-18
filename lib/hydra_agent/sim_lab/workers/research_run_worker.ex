defmodule HydraAgent.SimLab.Workers.ResearchRunWorker do
  @moduledoc """
  Durable, retryable boundary for provider-backed research.

  Only an allow-listed provider key and a research-run identifier enter Oban.
  The study question remains workspace-scoped in Postgres and provider queries
  are abstracted by the research planner before they leave the runtime.
  """

  use Oban.Worker,
    queue: :research,
    max_attempts: 3,
    unique: [fields: [:args], period: :infinity]

  import Ecto.Query

  alias HydraAgent.Repo
  alias HydraAgent.SimLab.{Notifications, Studies}

  alias HydraAgent.SimLab.Research.{
    CodexCliTestProvider,
    MockWebSearchProvider,
    Providers,
    Runner
  }

  alias HydraAgent.SimLab.Schemas.{ResearchRun, Study}

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"research_run_id" => id}} = job) do
    with %ResearchRun{} = run <- Repo.get(ResearchRun, id),
         %Study{} = study <- Repo.get(Study, run.study_id) do
      case run.status do
        status when status in ["completed", "cancelled"] -> :ok
        _status -> execute(job, run, study)
      end
    else
      nil -> {:discard, "research run or study no longer exists"}
    end
  rescue
    error -> fail_or_retry(job, id, Exception.message(error))
  end

  defp execute(job, run, study) do
    case claim_run(run) do
      {:ok, :finished} -> :ok
      {:ok, claimed} -> execute_claimed(job, claimed, study)
      {:error, reason} -> {:error, "research_claim_failed: #{inspect(reason)}"}
    end
  end

  defp execute_claimed(job, run, study) do
    Notifications.broadcast(study.id, %{kind: "research", status: "running", run_id: run.id})

    output =
      Runner.run(
        run.input_snapshot["question"] || study.question,
        run.input_snapshot,
        provider(run.provider),
        runner_opts(run)
      )

    case output.evidence do
      [] -> fail_or_retry(job, run.id, "provider_returned_no_evidence", length(output.failures))
      _ -> persist(run, study, output)
    end
  end

  defp claim_run(run) do
    Repo.transaction(fn ->
      current =
        ResearchRun
        |> where([current], current.id == ^run.id)
        |> lock("FOR UPDATE")
        |> Repo.one!()

      if current.status in ["completed", "cancelled"] do
        :finished
      else
        current
        |> ResearchRun.changeset(%{
          status: "running",
          started_at: current.started_at || DateTime.utc_now(),
          completed_at: nil,
          failure_reason: nil
        })
        |> Repo.update!()
      end
    end)
  end

  defp persist(run, study, output) do
    Repo.transaction(fn ->
      current =
        ResearchRun
        |> where([current], current.id == ^run.id)
        |> lock("FOR UPDATE")
        |> Repo.one!()

      if current.status == "completed" do
        %{completed: current, persisted: nil}
      else
        persisted =
          case Studies.persist_research_output(study, output) do
            {:ok, persisted} -> persisted
            {:error, reason} -> Repo.rollback({:persistence_failed, reason})
          end

        completed =
          current
          |> ResearchRun.changeset(%{
            status: "completed",
            source_count: length(persisted.sources),
            failed_lanes: length(output.failures),
            completed_at: DateTime.utc_now(),
            failure_reason: nil
          })
          |> Repo.update!()

        %{completed: completed, persisted: persisted}
      end
    end)
    |> case do
      {:ok, %{completed: completed, persisted: persisted}} ->
        context_pack_id = persisted && persisted.context_pack.id

        Notifications.broadcast(study.id, %{
          kind: "research",
          status: "completed",
          run_id: completed.id,
          context_pack_id: context_pack_id,
          source_count: completed.source_count,
          failed_lanes: completed.failed_lanes
        })

        :ok

      {:error, reason} ->
        {:error, "persistence_failed: #{inspect(reason)}"}
    end
  end

  defp fail_or_retry(job, run_id, reason, failed_lanes \\ 0)

  defp fail_or_retry(%Oban.Job{attempt: attempt, max_attempts: max}, run_id, reason, failed_lanes)
       when attempt >= max do
    case Repo.get(ResearchRun, run_id) do
      %ResearchRun{} = run ->
        {:ok, failed} =
          update_run(run, %{
            status: "failed",
            failed_lanes: failed_lanes,
            failure_reason: String.slice(reason, 0, 1_000),
            completed_at: DateTime.utc_now()
          })

        Notifications.broadcast(run.study_id, %{
          kind: "research",
          status: "failed",
          run_id: failed.id,
          reason: failed.failure_reason
        })

      nil ->
        :ok
    end

    {:cancel, reason}
  end

  defp fail_or_retry(_job, _run_id, reason, _failed_lanes), do: {:error, reason}

  defp update_run(run, attrs), do: run |> ResearchRun.changeset(attrs) |> Repo.update()

  defp provider("web_search"), do: Providers.web_search()
  defp provider("codex_cli_test"), do: CodexCliTestProvider
  defp provider("mock"), do: MockWebSearchProvider

  defp runner_opts(run) do
    private_entities = Map.get(run.input_snapshot, "private_entities", [])
    %{private_entities: private_entities}
  end
end
