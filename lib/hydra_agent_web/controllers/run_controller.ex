defmodule HydraAgentWeb.RunController do
  use HydraAgentWeb, :controller

  alias HydraAgent.Runtime
  alias HydraAgent.Agent.Supervisor, as: AgentSupervisor
  alias HydraAgent.Runtime.Planner
  alias HydraAgent.Runtime.Runner

  def index(conn, %{"workspace_id" => workspace_id} = params) do
    runs = Runtime.list_runs(workspace_id, params)
    json(conn, %{data: Enum.map(runs, &run_json/1)})
  end

  def show(conn, %{"workspace_id" => workspace_id, "id" => id}) do
    run = Runtime.get_run_for_workspace!(workspace_id, id)
    json(conn, %{data: run_json(run)})
  end

  def show(conn, %{"id" => id}) do
    run = Runtime.get_run!(id)
    json(conn, %{data: run_json(run)})
  end

  def create(conn, %{"workspace_id" => workspace_id} = params) do
    do_create(conn, Map.put(params, "workspace_id", workspace_id))
  end

  def create(conn, params) do
    do_create(conn, params)
  end

  defp do_create(conn, params) do
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

  def start(conn, %{"workspace_id" => workspace_id, "id" => id}) do
    run = Runtime.get_run_for_workspace!(workspace_id, id)
    render_result(conn, Runtime.start_run(run))
  end

  def start(conn, %{"id" => id}) do
    run = Runtime.get_run!(id)
    render_result(conn, Runtime.start_run(run))
  end

  def pause(conn, %{"workspace_id" => workspace_id, "id" => id} = params) do
    run = Runtime.get_run_for_workspace!(workspace_id, id)
    render_result(conn, Runtime.pause_run(run, params))
  end

  def pause(conn, %{"id" => id} = params) do
    run = Runtime.get_run!(id)
    render_result(conn, Runtime.pause_run(run, params))
  end

  def resume(conn, %{"workspace_id" => workspace_id, "id" => id} = params) do
    run = Runtime.get_run_for_workspace!(workspace_id, id)
    render_result(conn, Runtime.resume_run(run, params))
  end

  def resume(conn, %{"id" => id} = params) do
    run = Runtime.get_run!(id)
    render_result(conn, Runtime.resume_run(run, params))
  end

  def cancel(conn, %{"workspace_id" => workspace_id, "id" => id} = params) do
    run = Runtime.get_run_for_workspace!(workspace_id, id)

    case Runtime.cancel_run(run, params) do
      {:ok, canceled_run} ->
        worker_status = stop_worker_status(id)
        json(conn, %{data: run_json(canceled_run) |> Map.put(:worker_status, worker_status)})

      {:error, changeset} ->
        changeset_error(conn, changeset)
    end
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

  def retry(conn, %{"workspace_id" => workspace_id, "id" => id} = params) do
    run = Runtime.get_run_for_workspace!(workspace_id, id)
    render_result(conn, Runtime.retry_run(run, params))
  end

  def retry(conn, %{"id" => id} = params) do
    run = Runtime.get_run!(id)
    render_result(conn, Runtime.retry_run(run, params))
  end

  def fork(conn, %{"workspace_id" => workspace_id, "id" => id} = params) do
    run = Runtime.get_run_for_workspace!(workspace_id, id)
    render_result(conn, Runtime.fork_run(run, params))
  end

  def fork(conn, %{"id" => id} = params) do
    run = Runtime.get_run!(id)
    render_result(conn, Runtime.fork_run(run, params))
  end

  def trace(conn, %{"workspace_id" => workspace_id, "id" => id}) do
    json(conn, %{data: trace_json(Runtime.trace_run_for_workspace(workspace_id, id))})
  end

  def trace(conn, %{"id" => id}) do
    json(conn, %{data: trace_json(Runtime.trace_run(id))})
  end

  def steer(conn, %{"workspace_id" => workspace_id, "id" => id} = params) do
    run = Runtime.get_run_for_workspace!(workspace_id, id)
    render_result(conn, Runtime.steer_run(run, params))
  end

  def steer(conn, %{"id" => id} = params) do
    run = Runtime.get_run!(id)
    render_result(conn, Runtime.steer_run(run, params))
  end

  def plan(conn, %{"workspace_id" => workspace_id, "id" => id, "steps" => steps})
      when is_list(steps) do
    run = Runtime.get_run_for_workspace!(workspace_id, id)

    case Runner.plan_steps(run, steps) do
      {:ok, _steps} ->
        json(conn, %{data: run_json(Runtime.get_run_for_workspace!(workspace_id, id))})

      {:error, changeset} ->
        changeset_error(conn, changeset)
    end
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

  def generate_plan(conn, %{"workspace_id" => workspace_id, "id" => id} = params) do
    run = Runtime.get_run_for_workspace!(workspace_id, id)
    render_generate_plan(conn, run, params)
  end

  def generate_plan(conn, %{"id" => id} = params) do
    run = Runtime.get_run!(id)
    render_generate_plan(conn, run, params)
  end

  defp render_generate_plan(conn, run, params) do
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

  def execute_next(conn, %{"workspace_id" => workspace_id, "id" => id}) do
    run = Runtime.get_run_for_workspace!(workspace_id, id)
    render_execute_next(conn, run)
  end

  def execute_next(conn, %{"id" => id}) do
    run = Runtime.get_run!(id)
    render_execute_next(conn, run)
  end

  defp render_execute_next(conn, run) do
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

  def execute_parallel(conn, %{"workspace_id" => workspace_id, "id" => id} = params) do
    run = Runtime.get_run_for_workspace!(workspace_id, id)
    render_execute_parallel(conn, run, params)
  end

  def execute_parallel(conn, %{"id" => id} = params) do
    run = Runtime.get_run!(id)
    render_execute_parallel(conn, run, params)
  end

  defp render_execute_parallel(conn, run, params) do
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

  def start_worker(conn, %{"workspace_id" => workspace_id, "id" => id}) do
    Runtime.get_run_for_workspace!(workspace_id, id)
    start_worker(conn, %{"id" => id})
  end

  def start_worker(conn, %{"id" => id}) do
    case AgentSupervisor.start_run_worker(id) do
      {:ok, pid} ->
        json(conn, %{
          data:
            AgentSupervisor.run_worker_status(id)
            |> Map.merge(%{status: "started", pid: inspect(pid)})
        })

      {:error, {:already_started, pid}} ->
        json(conn, %{
          data:
            AgentSupervisor.run_worker_status(id)
            |> Map.merge(%{status: "already_started", pid: inspect(pid)})
        })

      {:error, reason} ->
        conn |> put_status(:unprocessable_entity) |> json(%{errors: %{reason: inspect(reason)}})
    end
  end

  def stop_worker(conn, %{"workspace_id" => workspace_id, "id" => id}) do
    Runtime.get_run_for_workspace!(workspace_id, id)
    json(conn, %{data: %{run_id: id, worker_status: stop_worker_status(id)}})
  end

  def stop_worker(conn, %{"id" => id}) do
    json(conn, %{data: %{run_id: id, worker_status: stop_worker_status(id)}})
  end

  def approve_step(
        conn,
        %{"workspace_id" => workspace_id, "id" => run_id, "step_id" => step_id} = params
      ) do
    step = Runtime.get_run_step_for_workspace!(workspace_id, run_id, step_id)
    render_step_result(conn, Runtime.approve_run_step(step, params))
  end

  def approve_step(conn, %{"step_id" => step_id} = params) do
    step = Runtime.get_run_step!(step_id)
    render_step_result(conn, Runtime.approve_run_step(step, params))
  end

  def reject_step(
        conn,
        %{"workspace_id" => workspace_id, "id" => run_id, "step_id" => step_id} = params
      ) do
    step = Runtime.get_run_step_for_workspace!(workspace_id, run_id, step_id)
    render_step_result(conn, Runtime.reject_run_step(step, params))
  end

  def reject_step(conn, %{"step_id" => step_id} = params) do
    step = Runtime.get_run_step!(step_id)
    render_step_result(conn, Runtime.reject_run_step(step, params))
  end

  defp run_json(run) do
    %{
      id: run.id,
      workspace_id: run.workspace_id,
      mission_id: run.mission_id,
      loop_id: run.loop_id,
      supervisor_agent_id: run.supervisor_agent_id,
      parent_run_id: run.parent_run_id,
      lineage_type: run.lineage_type,
      lineage_reason: run.lineage_reason,
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
      mission: assoc_json(run, :mission, &mission_json/1),
      loop: assoc_json(run, :loop, &loop_json/1),
      parent_run: assoc_json(run, :parent_run, &run_ref_json/1),
      child_runs:
        Enum.map((Ecto.assoc_loaded?(run.child_runs) && run.child_runs) || [], &run_ref_json/1),
      steps: Enum.map((Ecto.assoc_loaded?(run.steps) && run.steps) || [], &step_json/1),
      events: Enum.map((Ecto.assoc_loaded?(run.events) && run.events) || [], &event_json/1)
    }
  end

  defp run_ref_json(run) do
    %{
      id: run.id,
      mission_id: run.mission_id,
      loop_id: run.loop_id,
      parent_run_id: run.parent_run_id,
      lineage_type: run.lineage_type,
      title: run.title,
      goal: run.goal,
      status: run.status
    }
  end

  defp mission_json(mission) do
    %{
      id: mission.id,
      workspace_id: mission.workspace_id,
      supervisor_agent_id: mission.supervisor_agent_id,
      title: mission.title,
      slug: mission.slug,
      objective: mission.objective,
      mission_type: mission.mission_type,
      status: mission.status,
      priority: mission.priority,
      deadline_at: mission.deadline_at,
      start_mode: mission.start_mode
    }
  end

  defp loop_json(loop) do
    %{
      id: loop.id,
      workspace_id: loop.workspace_id,
      mission_id: loop.mission_id,
      supervisor_agent_id: loop.supervisor_agent_id,
      verifier_agent_id: loop.verifier_agent_id,
      name: loop.name,
      slug: loop.slug,
      status: loop.status,
      purpose: loop.purpose,
      trigger: loop.trigger,
      body: loop.body,
      autonomy_level: loop.autonomy_level,
      budget: loop.budget,
      guardrails: loop.guardrails,
      state: loop.state,
      last_error: loop.last_error,
      next_tick_at: loop.next_tick_at,
      last_tick_at: loop.last_tick_at,
      metadata: loop.metadata
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

  defp trace_json(trace) do
    %{
      run: run_json(trace.run),
      mission: trace.mission && mission_json(trace.mission),
      loop: trace.loop && loop_json(trace.loop),
      parent_run: trace.parent_run && run_ref_json(trace.parent_run),
      child_runs: Enum.map(trace.child_runs, &run_ref_json/1),
      steps: Enum.map(trace.steps, &step_json/1),
      events: Enum.map(trace.events, &event_json/1),
      knowledge_nodes: Enum.map(trace.knowledge_nodes, &knowledge_node_json/1),
      memory_nodes: Enum.map(trace.memory_nodes, &knowledge_node_json/1),
      artifact_nodes: Enum.map(trace.artifact_nodes, &knowledge_node_json/1),
      graph_relationships: Enum.map(trace.graph_relationships, &graph_relationship_json/1),
      safety_events: Enum.map(trace.safety_events, &safety_event_json/1),
      checkpoints: Enum.map(trace.checkpoints, &checkpoint_json/1),
      usage_records: Enum.map(trace.usage_records, &usage_record_json/1),
      usage_summary: trace.usage_summary
    }
  end

  defp knowledge_node_json(node) do
    %{
      id: node.id,
      workspace_id: node.workspace_id,
      type_key: node.type_key,
      title: node.title,
      body: node.body,
      status: node.status,
      attributes: node.attributes,
      importance: node.importance,
      confidence: node.confidence,
      provenance: node.provenance,
      created_by_agent_id: node.created_by_agent_id
    }
  end

  defp graph_relationship_json(relationship) do
    %{
      id: relationship.id,
      workspace_id: relationship.workspace_id,
      from_node_id: relationship.from_node_id,
      to_node_id: relationship.to_node_id,
      type_key: relationship.type_key,
      attributes: relationship.attributes,
      confidence: relationship.confidence,
      provenance: relationship.provenance,
      created_by_agent_id: relationship.created_by_agent_id,
      from_node: assoc_json(relationship, :from_node, &knowledge_node_ref_json/1),
      to_node: assoc_json(relationship, :to_node, &knowledge_node_ref_json/1)
    }
  end

  defp knowledge_node_ref_json(node) do
    %{
      id: node.id,
      type_key: node.type_key,
      title: node.title,
      status: node.status
    }
  end

  defp checkpoint_json(checkpoint) do
    %{
      id: checkpoint.id,
      workspace_id: checkpoint.workspace_id,
      run_id: checkpoint.run_id,
      run_step_id: checkpoint.run_step_id,
      tool_name: checkpoint.tool_name,
      path: checkpoint.path,
      relative_path: checkpoint.relative_path,
      checkpoint_path: checkpoint.checkpoint_path,
      sha256: checkpoint.sha256,
      existed: checkpoint.existed,
      restored_at: checkpoint.restored_at,
      metadata: checkpoint.metadata,
      inserted_at: checkpoint.inserted_at
    }
  end

  defp safety_event_json(event) do
    %{
      id: event.id,
      category: event.category,
      severity: event.severity,
      action: event.action,
      summary: event.summary,
      metadata: event.metadata,
      run_step_id: event.run_step_id,
      agent_id: event.agent_id,
      acknowledged_at: event.acknowledged_at,
      inserted_at: event.inserted_at
    }
  end

  defp usage_record_json(record) do
    %{
      id: record.id,
      provider: record.provider,
      model: record.model,
      category: record.category,
      status: record.status,
      input_tokens: record.input_tokens,
      output_tokens: record.output_tokens,
      total_tokens: record.total_tokens,
      estimated_cost: record.estimated_cost,
      latency_ms: record.latency_ms,
      metadata: record.metadata,
      agent_id: record.agent_id,
      run_step_id: record.run_step_id,
      conversation_id: record.conversation_id,
      turn_id: record.turn_id,
      inserted_at: record.inserted_at
    }
  end

  defp assoc_json(parent, assoc, mapper) do
    value = Map.get(parent, assoc)

    if Ecto.assoc_loaded?(value) and value do
      mapper.(value)
    end
  end

  defp render_result(conn, {:ok, run}), do: json(conn, %{data: run_json(run)})
  defp render_result(conn, {:error, changeset}), do: changeset_error(conn, changeset)

  defp render_step_result(conn, {:ok, step}), do: json(conn, %{data: step_json(step)})
  defp render_step_result(conn, {:error, changeset}), do: changeset_error(conn, changeset)

  defp stop_worker_status(run_id) do
    case AgentSupervisor.stop_run_worker(run_id) do
      :ok ->
        AgentSupervisor.run_worker_status(run_id) |> Map.put(:status, "stopped")

      {:error, :not_found} ->
        AgentSupervisor.run_worker_status(run_id) |> Map.put(:status, "not_found")

      {:error, reason} ->
        %{status: "error", reason: inspect(reason)}
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
