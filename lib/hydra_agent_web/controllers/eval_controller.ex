defmodule HydraAgentWeb.EvalController do
  use HydraAgentWeb, :controller

  alias HydraAgent.Evals

  def suites(conn, %{"workspace_id" => workspace_id}) do
    suites = Evals.list_suites(workspace_id)
    json(conn, %{data: Enum.map(suites, &suite_json/1)})
  end

  def show_suite(conn, %{"id" => id}) do
    suite = Evals.get_suite!(id)
    json(conn, %{data: suite_json(suite, include_cases: true)})
  end

  def create_suite(conn, %{"workspace_id" => workspace_id} = params) do
    create_suite(conn, Map.put(params, "workspace_id", workspace_id))
  end

  def create_suite(conn, params) do
    case Evals.create_suite(params) do
      {:ok, suite} ->
        conn |> put_status(:created) |> json(%{data: suite_json(suite)})

      {:error, changeset} ->
        conn |> put_status(:unprocessable_entity) |> json(%{errors: errors_json(changeset)})
    end
  end

  def create_case(conn, %{"suite_id" => suite_id} = params) do
    suite = Evals.get_suite!(suite_id)

    case Evals.create_case(suite, params) do
      {:ok, eval_case} ->
        conn |> put_status(:created) |> json(%{data: case_json(eval_case)})

      {:error, changeset} ->
        conn |> put_status(:unprocessable_entity) |> json(%{errors: errors_json(changeset)})
    end
  end

  def create_run(conn, params) do
    case Evals.create_run(params) do
      {:ok, run} ->
        conn |> put_status(:created) |> json(%{data: run_json(run)})

      {:error, changeset} ->
        conn |> put_status(:unprocessable_entity) |> json(%{errors: errors_json(changeset)})
    end
  end

  def show_run(conn, %{"id" => id}) do
    run = Evals.get_run!(id)
    json(conn, %{data: run_json(run, include_results: true)})
  end

  def execute_run(conn, %{"id" => id}) do
    run = Evals.get_run!(id)

    case Evals.execute_run(run) do
      {:ok, run} ->
        json(conn, %{data: run_json(Evals.get_run!(run.id), include_results: true)})

      {:error, changeset} ->
        conn |> put_status(:unprocessable_entity) |> json(%{errors: errors_json(changeset)})
    end
  end

  def report(conn, %{"id" => id}) do
    run = Evals.get_run!(id)
    json(conn, %{data: Evals.report(run)})
  end

  def benchmark(conn, %{"workspace_id" => workspace_id}) do
    json(conn, %{data: Evals.benchmark_report(workspace_id)})
  end

  def seed_benchmarks(conn, %{"workspace_id" => workspace_id}) do
    case Evals.seed_standard_benchmarks(workspace_id) do
      {:ok, suites} ->
        json(conn, %{data: Enum.map(suites, &suite_json(&1, include_cases: true))})

      {:error, errors} ->
        conn |> put_status(:unprocessable_entity) |> json(%{errors: inspect(errors)})
    end
  end

  defp suite_json(suite, opts \\ []) do
    base = %{
      id: suite.id,
      workspace_id: suite.workspace_id,
      name: suite.name,
      slug: suite.slug,
      description: suite.description,
      status: suite.status,
      metadata: suite.metadata
    }

    if Keyword.get(opts, :include_cases, false) do
      Map.put(base, :cases, Enum.map(loaded(suite.cases), &case_json/1))
    else
      base
    end
  end

  defp case_json(eval_case) do
    %{
      id: eval_case.id,
      workspace_id: eval_case.workspace_id,
      suite_id: eval_case.suite_id,
      name: eval_case.name,
      slug: eval_case.slug,
      prompt: eval_case.prompt,
      expected: eval_case.expected,
      scoring: eval_case.scoring,
      metadata: eval_case.metadata
    }
  end

  defp run_json(run, opts \\ []) do
    base = %{
      id: run.id,
      workspace_id: run.workspace_id,
      suite_id: run.suite_id,
      agent_id: run.agent_id,
      status: run.status,
      summary: run.summary,
      started_at: run.started_at,
      completed_at: run.completed_at,
      metadata: run.metadata
    }

    if Keyword.get(opts, :include_results, false) do
      Map.put(base, :results, Enum.map(loaded(run.results), &result_json/1))
    else
      base
    end
  end

  defp result_json(result) do
    %{
      id: result.id,
      eval_run_id: result.eval_run_id,
      eval_case_id: result.eval_case_id,
      status: result.status,
      score: result.score,
      output: result.output,
      error: result.error,
      metadata: result.metadata
    }
  end

  defp loaded(value), do: if(Ecto.assoc_loaded?(value), do: value, else: [])

  defp errors_json(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
      Enum.reduce(opts, message, fn {key, value}, acc ->
        String.replace(acc, "%{#{key}}", to_string(value))
      end)
    end)
  end
end
