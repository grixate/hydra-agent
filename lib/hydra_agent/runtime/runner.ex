defmodule HydraAgent.Runtime.Runner do
  @moduledoc """
  Minimal inspectable run orchestrator.

  The v1 runner executes durable steps one at a time. Every policy decision and
  state transition is written to the run event stream before or after execution.
  """

  alias HydraAgent.Repo
  alias HydraAgent.Runtime
  alias HydraAgent.Runtime.{AgentMatcher, AgentProfile, Authorizer, Run, RunStep}
  alias HydraAgent.Safety
  alias HydraAgent.Tools.Registry

  def plan_steps(%Run{} = run, steps) when is_list(steps) do
    agents = Runtime.list_agents(run.workspace_id)

    steps
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {attrs, index}, {:ok, planned} ->
      attrs =
        attrs
        |> stringify_keys()
        |> AgentMatcher.assign_step(agents)
        |> Map.put_new("index", index)

      case Runtime.create_run_step(run, attrs) do
        {:ok, step} -> {:cont, {:ok, planned ++ [step]}}
        {:error, changeset} -> {:halt, {:error, changeset}}
      end
    end)
  end

  def start(%Run{} = run), do: Runtime.start_run(run)

  def execute_next_step(%Run{} = run, opts \\ []) do
    lease_owner = Keyword.get(opts, :lease_owner, default_lease_owner())

    with :ok <- ensure_runnable(run),
         {:ok, step} <- Runtime.lease_next_step(run, lease_owner, opts) do
      case step do
        nil -> {:ok, :no_planned_steps}
        step -> execute_step(step, opts)
      end
    end
  end

  def execute_parallel_safe_batch(%Run{} = run, opts \\ []) do
    max_concurrency = opts |> Keyword.get(:max_concurrency, 4) |> max(1) |> min(32)
    lease_owner = Keyword.get(opts, :lease_owner, default_lease_owner())
    lease_opts = Keyword.merge(opts, max_steps: Keyword.get(opts, :max_steps, max_concurrency))

    with :ok <- ensure_runnable(run),
         {:ok, steps} <- Runtime.lease_parallel_safe_steps(run, lease_owner, lease_opts) do
      case steps do
        [] ->
          {:ok, []}

        steps ->
          results =
            steps
            |> Task.async_stream(
              fn step -> execute_step(step, Keyword.put(opts, :lease_owner, lease_owner)) end,
              max_concurrency: max_concurrency,
              timeout: :infinity
            )
            |> Enum.map(&normalize_batch_result/1)

          {:ok, results}
      end
    end
  end

  defp ensure_runnable(%Run{status: status}) when status in ["planned", "running"], do: :ok

  defp ensure_runnable(%Run{} = run) do
    {:error, %{"reason" => "run_not_runnable", "run_id" => run.id, "status" => run.status}}
  end

  def execute_step(%RunStep{} = step, opts \\ []) do
    step = Repo.preload(step, [:run, :assigned_agent])
    run = step.run
    lease_owner = Keyword.get(opts, :lease_owner, step.lease_owner)

    case active_lease?(step, lease_owner) do
      true -> do_execute_step(step, run, opts)
      false -> {:error, %{"reason" => "missing_or_expired_step_lease", "step_id" => step.id}}
    end
  end

  def recover_workspace(workspace_id, opts \\ []) do
    Runtime.recover_stale_steps(workspace_id, opts)
  end

  defp do_execute_step(%RunStep{} = step, %Run{} = run, _opts) do
    cond do
      is_nil(step.assigned_agent) ->
        block_step(step, "missing_assigned_agent", %{})

      is_nil(step.tool_name) ->
        block_step(step, "missing_tool_name", %{})

      true ->
        authorize_and_execute(step, run, step.assigned_agent)
    end
  end

  defp authorize_and_execute(step, run, %AgentProfile{} = agent) do
    case Authorizer.authorize(agent, step.tool_name,
           autonomy_level: run.autonomy_level,
           input: step.input
         ) do
      {:authorized, decision} ->
        execute_authorized_step(step, run, agent, decision)

      {:approval_required, decision} ->
        approval_required(step, run, agent, decision)

      {:blocked, decision} ->
        block_step(step, decision["reason"], decision)
    end
  end

  defp execute_authorized_step(step, run, agent, decision) do
    {:ok, running_step} = Runtime.heartbeat_step(step, step.lease_owner)

    record_event(running_step, run, "step.started", "Step started", decision)
    record_event(running_step, run, "tool.authorized", "Tool authorized", decision)

    context = %{
      "workspace_id" => run.workspace_id,
      "run_id" => run.id,
      "run_step_id" => running_step.id,
      "agent_id" => agent.id,
      "workspace_root" => get_in(run.metadata || %{}, ["workspace_root"])
    }

    case Registry.execute(running_step.tool_name, running_step.input, context) do
      {:ok, output} ->
        complete_step(running_step, run, output)

      {:error, error} ->
        fail_step(running_step, run, error)
    end
  end

  defp approval_required(step, run, agent, decision) do
    approval = %{
      "decision" => "required",
      "reason" => decision["reason"],
      "requested_at" => DateTime.to_iso8601(now())
    }

    {:ok, awaiting_step} =
      Runtime.release_step_lease(step, %{
        "status" => "awaiting_approval",
        "approval" => Map.merge(step.approval || %{}, approval)
      })

    {:ok, _run} = Runtime.transition_run(run, "awaiting_approval")

    record_event(awaiting_step, run, "step.awaiting_approval", "Step awaiting approval", decision)

    Safety.record_event(%{
      workspace_id: run.workspace_id,
      agent_id: agent.id,
      run_id: run.id,
      run_step_id: awaiting_step.id,
      category: "approval",
      severity: "warning",
      action: "tool_approval_required",
      summary: "Tool execution requires approval",
      metadata: decision
    })

    {:approval_required, awaiting_step}
  end

  defp block_step(step, reason, metadata) do
    run = step.run || Repo.get!(Run, step.run_id)

    {:ok, blocked_step} =
      Runtime.release_step_lease(step, %{
        "status" => "blocked",
        "error" => %{"reason" => reason, "metadata" => metadata},
        "completed_at" => now()
      })

    record_event(blocked_step, run, "step.blocked", "Step blocked", %{
      "reason" => reason,
      "metadata" => metadata
    })

    record_event(blocked_step, run, "tool.blocked", "Tool blocked", %{
      "reason" => reason,
      "metadata" => metadata
    })

    Safety.record_event(%{
      workspace_id: run.workspace_id,
      agent_id: blocked_step.assigned_agent_id,
      run_id: run.id,
      run_step_id: blocked_step.id,
      category: "tool_policy",
      severity: "warning",
      action: "tool_blocked",
      summary: "Tool execution blocked",
      metadata: %{"reason" => reason, "metadata" => metadata}
    })

    {:blocked, blocked_step}
  end

  defp complete_step(step, run, output) do
    {:ok, completed_step} =
      Runtime.release_step_lease(step, %{
        "status" => "completed",
        "output" => output,
        "completed_at" => now()
      })

    record_event(completed_step, run, "tool.executed", "Tool executed", %{"output" => output})
    record_event(completed_step, run, "step.completed", "Step completed", %{"output" => output})

    {:ok, completed_step}
  end

  defp fail_step(step, run, error) do
    {:ok, failed_step} =
      Runtime.release_step_lease(step, %{
        "status" => "failed",
        "error" => error,
        "completed_at" => now()
      })

    record_event(failed_step, run, "step.failed", "Step failed", %{"error" => error})
    Runtime.fail_run(run, %{"result" => %{"error" => error}})

    {:error, failed_step}
  end

  defp record_event(step, run, event_type, summary, payload) do
    Runtime.record_run_event(%{
      workspace_id: run.workspace_id,
      run_id: run.id,
      run_step_id: step.id,
      agent_id: step.assigned_agent_id,
      event_type: event_type,
      summary: summary,
      payload: payload
    })
  end

  defp stringify_keys(map) when is_map(map),
    do: Map.new(map, fn {key, value} -> {to_string(key), value} end)

  defp active_lease?(%RunStep{} = step, lease_owner) when is_binary(lease_owner) do
    step.status == "running" and step.lease_owner == lease_owner and
      not is_nil(step.lease_expires_at) and DateTime.compare(step.lease_expires_at, now()) == :gt
  end

  defp active_lease?(_step, _lease_owner), do: false

  defp normalize_batch_result({:ok, result}), do: result

  defp normalize_batch_result({:exit, reason}) do
    {:error, %{"reason" => "parallel_step_crashed", "error" => inspect(reason)}}
  end

  defp default_lease_owner do
    "runner:#{node()}:#{System.unique_integer([:positive])}"
  end

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:microsecond)
end
