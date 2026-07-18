defmodule HydraAgent.SimLab.Jobs do
  @moduledoc """
  Durable orchestration for research and simulation persistence.

  Provider-backed production research is stored as an inspectable run and
  executed by Oban. Function providers remain available only as an in-process
  test seam, because executable closures cannot be serialized safely.
  """

  import Ecto.Query

  alias HydraAgent.Repo
  alias HydraAgent.SimLab.{Notifications, Simulations, Studies}

  alias HydraAgent.SimLab.Research.{
    CodexCliTestProvider,
    MockWebSearchProvider,
    Providers,
    Runner
  }

  alias HydraAgent.SimLab.Schemas.ResearchRun
  alias HydraAgent.SimLab.Workers.ResearchRunWorker

  def start_research(%{id: study_id} = study, question, attrs \\ %{}, opts \\ %{}) do
    provider = Map.get(Map.new(opts), :provider, Providers.web_search())

    if is_function(provider, 1) do
      start_test_research(study, study_id, question, attrs, provider, opts)
    else
      enqueue_research(study, question, attrs, provider, opts)
    end
  end

  def list_research_runs(study_id) do
    ResearchRun
    |> where([run], run.study_id == ^study_id)
    |> order_by([run], desc: run.inserted_at)
    |> limit(10)
    |> Repo.all()
  end

  defp enqueue_research(study, question, attrs, provider, opts) do
    input_snapshot =
      attrs
      |> Map.new()
      |> stringify_keys()
      |> Map.put("question", question)
      |> Map.put(
        "private_entities",
        opts |> Map.new() |> Map.get(:private_entities, []) |> Enum.map(&to_string/1)
      )

    Repo.transaction(fn ->
      run =
        %ResearchRun{}
        |> ResearchRun.changeset(%{
          workspace_id: study.workspace_id,
          study_id: study.id,
          provider: provider_key(provider),
          input_snapshot: input_snapshot
        })
        |> Repo.insert!()

      case Oban.insert(ResearchRunWorker.new(%{"research_run_id" => run.id})) do
        {:ok, _job} -> run
        {:error, changeset} -> Repo.rollback(changeset)
      end
    end)
  end

  defp start_test_research(study, study_id, question, attrs, provider, opts) do
    Task.Supervisor.start_child(HydraAgent.TaskSupervisor, fn ->
      Notifications.broadcast(study_id, %{kind: "research", status: "running"})

      try do
        output = Runner.run(question, attrs, provider, opts)

        case output.evidence do
          [] ->
            Notifications.broadcast(study_id, %{
              kind: "research",
              status: "failed",
              reason: "provider_returned_no_evidence",
              failed_lanes: length(output.failures)
            })

          _evidence ->
            persist_research_output(study, study_id, output)
        end
      rescue
        _error ->
          Notifications.broadcast(study_id, %{
            kind: "research",
            status: "failed",
            reason: "execution_failed"
          })
      end
    end)
  end

  defp provider_key(CodexCliTestProvider), do: "codex_cli_test"
  defp provider_key(MockWebSearchProvider), do: "mock"
  defp provider_key(_provider), do: "web_search"

  defp stringify_keys(map),
    do: Map.new(map, fn {key, value} -> {to_string(key), value} end)

  defp persist_research_output(study, study_id, output) do
    case Studies.persist_research_output(study, output) do
      {:ok, persisted} ->
        Notifications.broadcast(study_id, %{
          kind: "research",
          status: "completed",
          context_pack_id: persisted.context_pack.id,
          source_count: length(persisted.sources),
          failed_lanes: length(output.failures)
        })

      {:error, _reason} ->
        Notifications.broadcast(study_id, %{
          kind: "research",
          status: "failed",
          reason: "persistence_failed"
        })
    end
  end

  @doc """
  Compatibility entry point for callers that previously delegated simulation
  work to a transient Task. New runs are always persisted and queued in Oban.
  """
  def start_simulation(study, scenario, context_pack, input, opts \\ %{}),
    do: Simulations.queue_run(study, scenario, context_pack, input, opts)
end
