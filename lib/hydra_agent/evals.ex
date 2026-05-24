defmodule HydraAgent.Evals do
  @moduledoc """
  Eval and benchmark primitives for measuring agent quality, safety, and regressions.
  """

  import Ecto.Query

  alias Ecto.Multi
  alias HydraAgent.AgentChat
  alias HydraAgent.Evals.{Case, Result, Run, Suite}
  alias HydraAgent.Repo

  def list_suites(workspace_id) do
    Suite
    |> where([suite], suite.workspace_id == ^workspace_id)
    |> order_by([suite], asc: suite.name)
    |> Repo.all()
  end

  def get_suite!(id), do: Repo.get!(Suite, id) |> Repo.preload([:cases])

  def create_suite(attrs) do
    %Suite{} |> Suite.changeset(stringify_keys(attrs)) |> Repo.insert()
  end

  def create_case(%Suite{} = suite, attrs) do
    attrs =
      attrs
      |> stringify_keys()
      |> Map.put("workspace_id", suite.workspace_id)
      |> Map.put("suite_id", suite.id)

    %Case{} |> Case.changeset(attrs) |> Repo.insert()
  end

  def create_run(attrs) do
    attrs = stringify_keys(attrs)

    Multi.new()
    |> Multi.insert(:run, %Run{} |> Run.changeset(attrs))
    |> Multi.run(:results, fn repo, %{run: run} ->
      cases =
        Case
        |> where([eval_case], eval_case.suite_id == ^run.suite_id)
        |> repo.all()

      results =
        Enum.map(cases, fn eval_case ->
          {:ok, result} =
            %Result{}
            |> Result.changeset(%{
              workspace_id: run.workspace_id,
              eval_run_id: run.id,
              eval_case_id: eval_case.id,
              status: "pending"
            })
            |> repo.insert()

          result
        end)

      {:ok, results}
    end)
    |> Repo.transaction()
    |> case do
      {:ok, %{run: run}} -> {:ok, Repo.preload(run, [:suite, :agent, :results])}
      {:error, _operation, changeset, _changes} -> {:error, changeset}
    end
  end

  def get_run!(id),
    do: Repo.get!(Run, id) |> Repo.preload([:suite, :agent, results: [:eval_case]])

  def report(%Run{} = run) do
    run =
      if Ecto.assoc_loaded?(run.results) do
        run
      else
        get_run!(run.id)
      end

    build_report(run)
  end

  def execute_run(%Run{} = run) do
    run = get_run!(run.id)
    now = now()

    {:ok, run} =
      run
      |> Run.changeset(%{status: "running", started_at: run.started_at || now})
      |> Repo.update()

    results =
      run.results
      |> Enum.map(&execute_result(&1, run.agent))

    summary = summarize_results(results)

    run
    |> Run.changeset(%{
      status: if(summary["errored"] > 0, do: "failed", else: "completed"),
      summary: summary,
      completed_at: now()
    })
    |> Repo.update()
  end

  defp execute_result(%Result{} = result, nil) do
    update_result(result, %{
      status: "errored",
      error: %{"reason" => "missing_eval_agent"}
    })
  end

  defp execute_result(%Result{} = result, agent) do
    eval_case = result.eval_case

    with {:ok, conversation} <-
           AgentChat.start_conversation(agent, %{
             title: "Eval: #{eval_case.name}",
             channel: "eval",
             metadata: %{"eval_case_id" => eval_case.id, "eval_run_id" => result.eval_run_id}
           }),
         {:ok, response} <-
           AgentChat.respond(conversation, eval_case.prompt,
             source: "eval",
             usage_category: "eval"
           ) do
      score = score_response(response.assistant_turn.content, eval_case.expected)

      update_result(result, %{
        status: if(score >= 1.0, do: "passed", else: "failed"),
        score: score,
        output: %{
          "conversation_id" => response.conversation.id,
          "assistant_turn_id" => response.assistant_turn.id,
          "content" => response.assistant_turn.content
        }
      })
    else
      {:error, error} ->
        update_result(result, %{status: "errored", error: normalize_error(error)})
    end
  end

  defp update_result(result, attrs) do
    {:ok, result} = result |> Result.changeset(attrs) |> Repo.update()
    result
  end

  defp score_response(content, %{"contains" => contains}) when is_list(contains) do
    if Enum.all?(
         contains,
         &String.contains?(String.downcase(content), String.downcase(to_string(&1)))
       ) do
      1.0
    else
      0.0
    end
  end

  defp score_response(_content, _expected), do: 0.0

  defp summarize_results(results) do
    total = length(results)
    passed = Enum.count(results, &(&1.status == "passed"))
    failed = Enum.count(results, &(&1.status == "failed"))
    errored = Enum.count(results, &(&1.status == "errored"))

    %{
      "total" => total,
      "passed" => passed,
      "failed" => failed,
      "errored" => errored,
      "pass_rate" => if(total == 0, do: 0.0, else: passed / total)
    }
  end

  def build_report(%Run{} = run) do
    results = loaded(run.results)
    summary = summarize_results(results)
    scores = results |> Enum.map(& &1.score) |> Enum.reject(&is_nil/1)

    %{
      "eval_run_id" => run.id,
      "workspace_id" => run.workspace_id,
      "suite_id" => run.suite_id,
      "agent_id" => run.agent_id,
      "status" => run.status,
      "summary" => summary,
      "quality" => %{
        "average_score" => average(scores),
        "scored_results" => length(scores),
        "pass_rate" => summary["pass_rate"]
      },
      "timing" => %{
        "started_at" => run.started_at,
        "completed_at" => run.completed_at,
        "duration_ms" => duration_ms(run.started_at, run.completed_at)
      },
      "failures" =>
        results
        |> Enum.filter(&(&1.status in ["failed", "errored"]))
        |> Enum.map(&result_report/1)
    }
  end

  defp result_report(result) do
    %{
      "result_id" => result.id,
      "eval_case_id" => result.eval_case_id,
      "case_slug" => loaded_case_slug(result),
      "status" => result.status,
      "score" => result.score,
      "error" => result.error
    }
  end

  defp average([]), do: 0.0
  defp average(values), do: Enum.sum(values) / length(values)

  defp duration_ms(%DateTime{} = started_at, %DateTime{} = completed_at) do
    DateTime.diff(completed_at, started_at, :millisecond)
  end

  defp duration_ms(_started_at, _completed_at), do: nil

  defp loaded_case_slug(result) do
    if Ecto.assoc_loaded?(result.eval_case) and result.eval_case do
      result.eval_case.slug
    end
  end

  defp loaded(value), do: if(Ecto.assoc_loaded?(value), do: value, else: [])

  defp normalize_error(%Ecto.Changeset{} = changeset),
    do: %{"reason" => "changeset_error", "errors" => changeset_errors(changeset)}

  defp normalize_error(error) when is_map(error), do: error
  defp normalize_error(error), do: %{"reason" => inspect(error)}

  defp changeset_errors(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
      Enum.reduce(opts, message, fn {key, value}, acc ->
        String.replace(acc, "%{#{key}}", to_string(value))
      end)
    end)
  end

  defp stringify_keys(map) when is_map(map),
    do: Map.new(map, fn {key, value} -> {to_string(key), value} end)

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:microsecond)
end
