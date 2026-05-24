defmodule HydraAgentWeb.RunController do
  use HydraAgentWeb, :controller

  alias HydraAgent.Runtime
  alias HydraAgent.Agent.Supervisor, as: AgentSupervisor
  alias HydraAgent.Runtime.Planner
  alias HydraAgent.Runtime.Runner

  def index(conn, %{"workspace_id" => workspace_id}) do
    runs = Runtime.list_runs(workspace_id)
    json(conn, %{data: Enum.map(runs, &run_json/1)})
  end

  def show(conn, %{"id" => id}) do
    run = Runtime.get_run!(id)
    json(conn, %{data: run_json(run)})
  end

  def create(conn, params) do
    case Runtime.create_run(params) do
      {:ok, run} ->
        conn
        |> put_status(:created)
        |> json(%{data: run_json(run)})

      {:error, changeset} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{errors: errors_json(changeset)})
    end
  end

  def start(conn, %{"id" => id}) do
    run = Runtime.get_run!(id)
    render_result(conn, Runtime.start_run(run))
  end

  def pause(conn, %{"id" => id} = params) do
    run = Runtime.get_run!(id)
    render_result(conn, Runtime.pause_run(run, params))
  end

  def resume(conn, %{"id" => id} = params) do
    run = Runtime.get_run!(id)
    render_result(conn, Runtime.resume_run(run, params))
  end

  def cancel(conn, %{"id" => id} = params) do
    run = Runtime.get_run!(id)

    case Runtime.cancel_run(run, params) do
      {:ok, canceled_run} ->
        worker_status = stop_worker_status(id)
        json(conn, %{data: run_json(canceled_run) |> Map.put(:worker_status, worker_status)})

      {:error, changeset} ->
        changeset_error(conn, changeset)
    end
  end

  def steer(conn, %{"id" => id} = params) do
    run = Runtime.get_run!(id)
    render_result(conn, Runtime.steer_run(run, params))
  end

  def plan(conn, %{"id" => id, "steps" => steps}) when is_list(steps) do
    run = Runtime.get_run!(id)

    case Runner.plan_steps(run, steps) do
      {:ok, _steps} -> json(conn, %{data: run_json(Runtime.get_run!(id))})
      {:error, changeset} -> changeset_error(conn, changeset)
    end
  end

  def plan(conn, _params) do
    conn
    |> put_status(:bad_request)
    |> json(%{errors: %{"steps" => ["must be a list"]}})
  end

  def generate_plan(conn, %{"id" => id} = params) do
    run = Runtime.get_run!(id)

    case Planner.generate_plan(run,
           temperature: params["temperature"],
           max_tokens: params["max_tokens"]
         ) do
      {:ok, response} ->
        json(conn, %{
          data: %{
            run: run_json(response.run),
            steps: Enum.map(response.steps, &step_json/1),
            provider_response: response.provider_response
          }
        })

      {:error, error} when is_map(error) ->
        conn |> put_status(:unprocessable_entity) |> json(%{errors: error})

      {:error, changeset} ->
        changeset_error(conn, changeset)
    end
  end

  def execute_next(conn, %{"id" => id}) do
    run = Runtime.get_run!(id)

    case Runner.execute_next_step(run) do
      {:ok, :no_planned_steps} ->
        json(conn, %{data: %{status: "idle", reason: "no_planned_steps"}})

      {:ok, step} ->
        json(conn, %{data: step_json(step)})

      {:approval_required, step} ->
        json(conn, %{data: step_json(step)})

      {:blocked, step} ->
        conn |> put_status(:conflict) |> json(%{data: step_json(step)})

      {:error, %HydraAgent.Runtime.RunStep{} = step} ->
        conn |> put_status(:unprocessable_entity) |> json(%{data: step_json(step)})

      {:error, error} when is_map(error) ->
        conn |> put_status(:unprocessable_entity) |> json(%{errors: error})

      {:error, step} ->
        conn |> put_status(:unprocessable_entity) |> json(%{errors: %{reason: inspect(step)}})
    end
  end

  def execute_parallel(conn, %{"id" => id} = params) do
    run = Runtime.get_run!(id)

    opts = [
      max_concurrency: parse_int(params["max_concurrency"], 4),
      max_steps: parse_int(params["max_steps"], parse_int(params["max_concurrency"], 4))
    ]

    case Runner.execute_parallel_safe_batch(run, opts) do
      {:ok, []} ->
        json(conn, %{data: %{status: "idle", reason: "no_parallel_safe_steps", results: []}})

      {:ok, results} ->
        json(conn, %{
          data: %{status: "completed", results: Enum.map(results, &step_result_json/1)}
        })

      {:error, reason} ->
        conn |> put_status(:unprocessable_entity) |> json(%{errors: %{reason: inspect(reason)}})
    end
  end

  def start_worker(conn, %{"id" => id}) do
    case AgentSupervisor.start_run_worker(id) do
      {:ok, pid} ->
        json(conn, %{data: %{status: "started", pid: inspect(pid)}})

      {:error, {:already_started, pid}} ->
        json(conn, %{data: %{status: "already_started", pid: inspect(pid)}})

      {:error, reason} ->
        conn |> put_status(:unprocessable_entity) |> json(%{errors: %{reason: inspect(reason)}})
    end
  end

  def stop_worker(conn, %{"id" => id}) do
    json(conn, %{data: %{run_id: id, worker_status: stop_worker_status(id)}})
  end

  def approve_step(conn, %{"step_id" => step_id} = params) do
    step = Runtime.get_run_step!(step_id)
    render_step_result(conn, Runtime.approve_run_step(step, params))
  end

  def reject_step(conn, %{"step_id" => step_id} = params) do
    step = Runtime.get_run_step!(step_id)
    render_step_result(conn, Runtime.reject_run_step(step, params))
  end

  defp run_json(run) do
    %{
      id: run.id,
      workspace_id: run.workspace_id,
      supervisor_agent_id: run.supervisor_agent_id,
      title: run.title,
      goal: run.goal,
      status: run.status,
      autonomy_level: run.autonomy_level,
      priority: run.priority,
      budget: run.budget,
      plan: run.plan,
      result: run.result,
      runtime_state: run.runtime_state,
      metadata: run.metadata,
      steps: Enum.map((Ecto.assoc_loaded?(run.steps) && run.steps) || [], &step_json/1),
      events: Enum.map((Ecto.assoc_loaded?(run.events) && run.events) || [], &event_json/1)
    }
  end

  defp step_json(step) do
    %{
      id: step.id,
      index: step.index,
      title: step.title,
      status: step.status,
      assigned_agent_id: step.assigned_agent_id,
      tool_name: step.tool_name,
      side_effect_class: step.side_effect_class,
      input: step.input,
      output: step.output,
      approval: step.approval,
      error: step.error
    }
  end

  defp step_result_json({:ok, step}), do: %{status: "ok", step: step_json(step)}

  defp step_result_json({:approval_required, step}),
    do: %{status: "approval_required", step: step_json(step)}

  defp step_result_json({:blocked, step}), do: %{status: "blocked", step: step_json(step)}

  defp step_result_json({:error, %HydraAgent.Runtime.RunStep{} = step}),
    do: %{status: "error", step: step_json(step)}

  defp step_result_json({:error, error}), do: %{status: "error", error: error}

  defp event_json(event) do
    %{
      id: event.id,
      event_type: event.event_type,
      summary: event.summary,
      payload: event.payload,
      run_step_id: event.run_step_id,
      agent_id: event.agent_id,
      inserted_at: event.inserted_at
    }
  end

  defp render_result(conn, {:ok, run}), do: json(conn, %{data: run_json(run)})
  defp render_result(conn, {:error, changeset}), do: changeset_error(conn, changeset)

  defp render_step_result(conn, {:ok, step}), do: json(conn, %{data: step_json(step)})
  defp render_step_result(conn, {:error, changeset}), do: changeset_error(conn, changeset)

  defp stop_worker_status(run_id) do
    case AgentSupervisor.stop_run_worker(run_id) do
      :ok -> "stopped"
      {:error, :not_found} -> "not_found"
      {:error, reason} -> inspect(reason)
    end
  end

  defp parse_int(value, _default) when is_integer(value), do: value

  defp parse_int(value, default) when is_binary(value) do
    case Integer.parse(value) do
      {integer, ""} -> integer
      _parsed -> default
    end
  end

  defp parse_int(_value, default), do: default

  defp changeset_error(conn, changeset) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{errors: errors_json(changeset)})
  end

  defp errors_json(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
      Enum.reduce(opts, message, fn {key, value}, acc ->
        String.replace(acc, "%{#{key}}", to_string(value))
      end)
    end)
  end
end
