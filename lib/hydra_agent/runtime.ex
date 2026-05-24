defmodule HydraAgent.Runtime do
  @moduledoc """
  Runtime facade for workspaces, agents, conversations, runs, policies, and providers.
  """

  import Ecto.Query

  alias Ecto.Multi
  alias HydraAgent.Repo
  alias HydraAgent.Tools.Registry, as: ToolRegistry

  alias HydraAgent.Runtime.{
    AgentProfile,
    Conversation,
    ProviderConfig,
    Run,
    RunEvent,
    RunStep,
    ToolPolicy,
    Turn,
    Workspace
  }

  def list_workspaces do
    Workspace |> order_by([w], asc: w.name) |> Repo.all()
  end

  def list_workspace_ids do
    Workspace
    |> where([workspace], workspace.status == "active")
    |> select([workspace], workspace.id)
    |> Repo.all()
  end

  def get_workspace!(id), do: Repo.get!(Workspace, id)

  def create_workspace(attrs) do
    %Workspace{} |> Workspace.changeset(attrs) |> Repo.insert()
  end

  def list_agents(workspace_id) do
    AgentProfile
    |> where([a], a.workspace_id == ^workspace_id)
    |> order_by([a], asc: a.name)
    |> Repo.all()
  end

  def get_agent!(id), do: Repo.get!(AgentProfile, id)

  def create_agent(attrs) do
    attrs = put_default_capabilities(attrs)
    %AgentProfile{} |> AgentProfile.changeset(attrs) |> Repo.insert()
  end

  def create_provider(attrs) do
    %ProviderConfig{} |> ProviderConfig.changeset(attrs) |> Repo.insert()
  end

  def list_providers(workspace_id) do
    ProviderConfig
    |> where([provider], is_nil(provider.workspace_id) or provider.workspace_id == ^workspace_id)
    |> order_by([provider], asc: provider.name)
    |> Repo.all()
  end

  def get_provider!(id), do: Repo.get!(ProviderConfig, id)

  def create_tool_policy(attrs) do
    %ToolPolicy{} |> ToolPolicy.changeset(attrs) |> Repo.insert()
  end

  def list_tool_policies(workspace_id) do
    ToolPolicy
    |> where([policy], policy.workspace_id == ^workspace_id)
    |> order_by([policy], desc: policy.inserted_at)
    |> Repo.all()
  end

  def get_tool_policy!(id), do: Repo.get!(ToolPolicy, id)

  def create_conversation(attrs) do
    %Conversation{} |> Conversation.changeset(attrs) |> Repo.insert()
  end

  def list_conversations(workspace_id) do
    Conversation
    |> where([conversation], conversation.workspace_id == ^workspace_id)
    |> order_by([conversation], desc: conversation.last_message_at, desc: conversation.updated_at)
    |> preload([:agent])
    |> Repo.all()
  end

  def get_conversation!(id) do
    Conversation
    |> Repo.get!(id)
    |> Repo.preload([:agent, turns: from(turn in Turn, order_by: [asc: turn.inserted_at])])
  end

  def append_turn(%Conversation{} = conversation, attrs) do
    attrs =
      attrs
      |> stringify_keys()
      |> Map.put("conversation_id", conversation.id)

    Multi.new()
    |> Multi.insert(:turn, %Turn{} |> Turn.changeset(attrs))
    |> Multi.update(:conversation, fn %{turn: turn} ->
      Conversation.changeset(conversation, %{"last_message_at" => turn.inserted_at})
    end)
    |> Repo.transaction()
    |> case do
      {:ok, %{turn: turn, conversation: updated_conversation}} ->
        HydraAgent.Runtime.PubSub.broadcast_turn(updated_conversation, turn)
        {:ok, turn}

      {:error, _operation, changeset, _changes} ->
        {:error, changeset}
    end
  end

  def list_turns(conversation_id) do
    Turn
    |> where([turn], turn.conversation_id == ^conversation_id)
    |> order_by([turn], asc: turn.inserted_at)
    |> Repo.all()
  end

  def create_run(attrs) do
    run_changeset = %Run{} |> Run.changeset(attrs)

    Multi.new()
    |> Multi.insert(:run, run_changeset)
    |> Multi.insert(:event, fn %{run: run} ->
      RunEvent.changeset(%RunEvent{}, %{
        workspace_id: run.workspace_id,
        run_id: run.id,
        agent_id: run.supervisor_agent_id,
        event_type: "run.created",
        summary: "Run created",
        payload: %{"title" => run.title, "autonomy_level" => run.autonomy_level}
      })
    end)
    |> Repo.transaction()
    |> case do
      {:ok, %{run: run, event: event}} ->
        HydraAgent.Runtime.PubSub.broadcast_run_event(event)
        run = Repo.preload(run, [:supervisor_agent, :steps, :events])
        HydraAgent.Runtime.PubSub.broadcast_run(run)
        {:ok, run}

      {:error, _operation, changeset, _changes} ->
        {:error, changeset}
    end
  end

  def create_run_step(%Run{} = run, attrs) do
    attrs =
      attrs
      |> stringify_keys()
      |> Map.put("run_id", run.id)

    step_changeset = %RunStep{} |> RunStep.changeset(attrs)

    Multi.new()
    |> Multi.insert(:step, step_changeset)
    |> Multi.insert(:event, fn %{step: step} ->
      RunEvent.changeset(%RunEvent{}, %{
        workspace_id: run.workspace_id,
        run_id: run.id,
        run_step_id: step.id,
        agent_id: step.assigned_agent_id,
        event_type: "step.planned",
        summary: "Step planned",
        payload: %{"title" => step.title, "tool_name" => step.tool_name}
      })
    end)
    |> Repo.transaction()
    |> case do
      {:ok, %{step: step, event: event}} ->
        HydraAgent.Runtime.PubSub.broadcast_run_event(event)
        {:ok, step}

      {:error, _operation, changeset, _changes} ->
        {:error, changeset}
    end
  end

  def list_runs(workspace_id) do
    Run
    |> where([r], r.workspace_id == ^workspace_id)
    |> order_by([r], desc: r.inserted_at)
    |> preload([:supervisor_agent, :steps, :events])
    |> Repo.all()
  end

  def get_run!(id) do
    Run
    |> Repo.get!(id)
    |> Repo.preload([:supervisor_agent, :steps, :events])
  end

  def get_run_step!(id) do
    RunStep
    |> Repo.get!(id)
    |> Repo.preload([:run, :assigned_agent])
  end

  def list_awaiting_approval_steps(workspace_id) do
    RunStep
    |> join(:inner, [step], run in assoc(step, :run))
    |> where([step, run], run.workspace_id == ^workspace_id)
    |> where([step], step.status == "awaiting_approval")
    |> order_by([step], asc: step.inserted_at)
    |> preload([step, run], [:assigned_agent, run: run])
    |> Repo.all()
  end

  def list_run_events(run_id) do
    RunEvent
    |> where([event], event.run_id == ^run_id)
    |> order_by([event], asc: event.inserted_at)
    |> Repo.all()
  end

  def record_run_event(attrs) do
    %RunEvent{}
    |> RunEvent.changeset(attrs)
    |> Repo.insert()
    |> case do
      {:ok, event} ->
        HydraAgent.Runtime.PubSub.broadcast_run_event(event)
        {:ok, event}

      error ->
        error
    end
  end

  def step_status_counts(run_id) do
    RunStep
    |> where([step], step.run_id == ^run_id)
    |> group_by([step], step.status)
    |> select([step], {step.status, count(step.id)})
    |> Repo.all()
    |> Map.new()
  end

  def lease_next_step(%Run{} = run, lease_owner, opts \\ []) when is_binary(lease_owner) do
    lease_ms = Keyword.get(opts, :lease_ms, 60_000)
    leased_until = DateTime.add(now(), lease_ms, :millisecond)

    Repo.transaction(fn ->
      step =
        RunStep
        |> where([step], step.run_id == ^run.id and step.status == "planned")
        |> order_by([step], asc: step.index)
        |> lock("FOR UPDATE SKIP LOCKED")
        |> limit(1)
        |> Repo.one()

      case step do
        nil ->
          nil

        step ->
          {:ok, leased_step} =
            step
            |> RunStep.changeset(%{
              "status" => "running",
              "started_at" => step.started_at || now(),
              "heartbeat_at" => now(),
              "lease_owner" => lease_owner,
              "lease_expires_at" => leased_until,
              "attempt_count" => step.attempt_count + 1
            })
            |> Repo.update()

          {:ok, _event} =
            record_run_event(%{
              workspace_id: run.workspace_id,
              run_id: run.id,
              run_step_id: leased_step.id,
              agent_id: leased_step.assigned_agent_id,
              event_type: "step.leased",
              summary: "Step lease acquired",
              payload: %{
                "lease_owner" => lease_owner,
                "lease_expires_at" => DateTime.to_iso8601(leased_until),
                "attempt_count" => leased_step.attempt_count
              }
            })

          leased_step
      end
    end)
    |> case do
      {:ok, nil} -> {:ok, nil}
      {:ok, step} -> {:ok, Repo.preload(step, [:run, :assigned_agent])}
      {:error, reason} -> {:error, reason}
    end
  end

  def lease_parallel_safe_steps(%Run{} = run, lease_owner, opts \\ [])
      when is_binary(lease_owner) do
    lease_ms = Keyword.get(opts, :lease_ms, 60_000)
    max_steps = opts |> Keyword.get(:max_steps, 4) |> max(1) |> min(32)
    leased_until = DateTime.add(now(), lease_ms, :millisecond)
    parallel_safe_tool_names = ToolRegistry.parallel_safe_names()

    Repo.transaction(fn ->
      steps =
        RunStep
        |> where([step], step.run_id == ^run.id and step.status == "planned")
        |> where([step], step.side_effect_class == "read_only")
        |> where([step], step.tool_name in ^parallel_safe_tool_names)
        |> order_by([step], asc: step.index)
        |> lock("FOR UPDATE SKIP LOCKED")
        |> limit(^max_steps)
        |> Repo.all()

      Enum.map(steps, fn step ->
        {:ok, leased_step} =
          step
          |> RunStep.changeset(%{
            "status" => "running",
            "started_at" => step.started_at || now(),
            "heartbeat_at" => now(),
            "lease_owner" => lease_owner,
            "lease_expires_at" => leased_until,
            "attempt_count" => step.attempt_count + 1
          })
          |> Repo.update()

        {:ok, _event} =
          record_run_event(%{
            workspace_id: run.workspace_id,
            run_id: run.id,
            run_step_id: leased_step.id,
            agent_id: leased_step.assigned_agent_id,
            event_type: "step.leased",
            summary: "Parallel-safe step lease acquired",
            payload: %{
              "lease_owner" => lease_owner,
              "lease_expires_at" => DateTime.to_iso8601(leased_until),
              "attempt_count" => leased_step.attempt_count,
              "parallel_safe" => true
            }
          })

        leased_step
      end)
    end)
    |> case do
      {:ok, steps} -> {:ok, Repo.preload(steps, [:run, :assigned_agent])}
      {:error, reason} -> {:error, reason}
    end
  end

  def heartbeat_step(%RunStep{} = step, lease_owner, opts \\ []) when is_binary(lease_owner) do
    lease_ms = Keyword.get(opts, :lease_ms, 60_000)
    leased_until = DateTime.add(now(), lease_ms, :millisecond)

    if step.lease_owner != lease_owner do
      {:error, :lease_owner_mismatch}
    else
      step
      |> RunStep.changeset(%{
        "heartbeat_at" => now(),
        "lease_expires_at" => leased_until
      })
      |> Repo.update()
      |> case do
        {:ok, updated_step} ->
          run = step.run || Repo.get!(Run, updated_step.run_id)

          record_run_event(%{
            workspace_id: run.workspace_id,
            run_id: run.id,
            run_step_id: updated_step.id,
            agent_id: updated_step.assigned_agent_id,
            event_type: "step.heartbeat",
            summary: "Step heartbeat recorded",
            payload: %{
              "lease_owner" => lease_owner,
              "lease_expires_at" => DateTime.to_iso8601(leased_until)
            }
          })

          {:ok, updated_step}

        error ->
          error
      end
    end
  end

  def release_step_lease(%RunStep{} = step, attrs \\ %{}) do
    attrs =
      attrs
      |> stringify_keys()
      |> Map.merge(%{
        "lease_owner" => nil,
        "lease_expires_at" => nil,
        "heartbeat_at" => nil
      })

    transition_step(step, Map.get(attrs, "status", step.status), attrs)
  end

  def recover_stale_steps(workspace_id, opts \\ []) do
    stale_before = Keyword.get(opts, :stale_before, now())
    max_attempts = Keyword.get(opts, :max_attempts, 3)

    RunStep
    |> join(:inner, [step], run in assoc(step, :run))
    |> where([step, run], run.workspace_id == ^workspace_id)
    |> where([step], step.status == "running")
    |> where([step], not is_nil(step.lease_expires_at) and step.lease_expires_at < ^stale_before)
    |> preload([step, _run], [:run])
    |> Repo.all()
    |> Enum.map(fn step ->
      next_status = if step.attempt_count >= max_attempts, do: "failed", else: "planned"

      error =
        if next_status == "failed" do
          Map.merge(step.error || %{}, %{
            "reason" => "lease_expired",
            "max_attempts" => max_attempts
          })
        else
          step.error || %{}
        end

      {:ok, updated_step} =
        release_step_lease(step, %{
          "status" => next_status,
          "error" => error,
          "completed_at" => if(next_status == "failed", do: now(), else: nil)
        })

      record_run_event(%{
        workspace_id: step.run.workspace_id,
        run_id: step.run_id,
        run_step_id: step.id,
        agent_id: step.assigned_agent_id,
        event_type: if(next_status == "failed", do: "step.failed", else: "step.retrying"),
        summary:
          if(next_status == "failed",
            do: "Step failed after expired lease",
            else: "Step returned to planned after expired lease"
          ),
        payload: %{"attempt_count" => step.attempt_count, "max_attempts" => max_attempts}
      })

      updated_step
    end)
  end

  def transition_run(%Run{} = run, status, attrs \\ %{}) do
    run
    |> Run.changeset(Map.merge(stringify_keys(attrs), %{"status" => status}))
    |> Repo.update()
  end

  def start_run(%Run{} = run) do
    update_run_with_event(run, "running", %{"started_at" => now()}, "run.started", "Run started")
  end

  def pause_run(%Run{} = run, attrs \\ %{}) do
    update_run_with_event(run, "paused", attrs, "run.paused", "Run paused")
  end

  def resume_run(%Run{} = run, attrs \\ %{}) do
    update_run_with_event(run, "running", attrs, "run.resumed", "Run resumed")
  end

  def cancel_run(%Run{} = run, attrs \\ %{}) do
    attrs = Map.put_new(stringify_keys(attrs), "completed_at", now())
    update_run_with_event(run, "canceled", attrs, "run.canceled", "Run canceled")
  end

  def complete_run(%Run{} = run, attrs \\ %{}) do
    attrs = Map.put_new(stringify_keys(attrs), "completed_at", now())
    update_run_with_event(run, "completed", attrs, "run.completed", "Run completed")
  end

  def fail_run(%Run{} = run, attrs \\ %{}) do
    attrs = Map.put_new(stringify_keys(attrs), "completed_at", now())
    update_run_with_event(run, "failed", attrs, "run.failed", "Run failed")
  end

  def steer_run(%Run{} = run, attrs) do
    attrs = stringify_keys(attrs)
    actor = Map.get(attrs, "actor", "operator")
    content = Map.get(attrs, "content", "")

    steering_entry = %{
      "actor" => actor,
      "content" => content,
      "inserted_at" => DateTime.to_iso8601(now())
    }

    runtime_state =
      run.runtime_state
      |> append_state_entry("steering", steering_entry)
      |> Map.put("last_steering", steering_entry)

    update_run_with_event(
      run,
      run.status,
      %{"runtime_state" => runtime_state},
      "run.steered",
      "Run steering added",
      %{"actor" => actor, "content" => content}
    )
  end

  def approve_run_step(%RunStep{} = step, attrs \\ %{}) do
    transition_step_with_event(
      step,
      "planned",
      approval_attrs(step, attrs, "approved"),
      "step.approved",
      "Step approved"
    )
  end

  def reject_run_step(%RunStep{} = step, attrs \\ %{}) do
    transition_step_with_event(
      step,
      "canceled",
      approval_attrs(step, attrs, "rejected"),
      "step.rejected",
      "Step rejected"
    )
  end

  def transition_step(%RunStep{} = step, status, attrs \\ %{}) do
    step
    |> RunStep.changeset(Map.merge(stringify_keys(attrs), %{"status" => status}))
    |> Repo.update()
  end

  defp update_run_with_event(run, status, attrs, event_type, summary, payload \\ %{}) do
    attrs = Map.merge(stringify_keys(attrs), %{"status" => status})

    Multi.new()
    |> Multi.update(:run, Run.changeset(run, attrs))
    |> Multi.insert(:event, fn %{run: updated_run} ->
      RunEvent.changeset(%RunEvent{}, %{
        workspace_id: updated_run.workspace_id,
        run_id: updated_run.id,
        agent_id: updated_run.supervisor_agent_id,
        event_type: event_type,
        summary: summary,
        payload: payload
      })
    end)
    |> Repo.transaction()
    |> case do
      {:ok, %{run: updated_run, event: event}} ->
        HydraAgent.Runtime.PubSub.broadcast_run_event(event)
        updated_run = Repo.preload(updated_run, [:supervisor_agent, :steps, :events])
        HydraAgent.Runtime.PubSub.broadcast_run(updated_run)
        {:ok, updated_run}

      {:error, _operation, changeset, _changes} ->
        {:error, changeset}
    end
  end

  defp transition_step_with_event(step, status, attrs, event_type, summary) do
    attrs = Map.merge(stringify_keys(attrs), %{"status" => status})

    Multi.new()
    |> Multi.update(:step, RunStep.changeset(step, attrs))
    |> Multi.insert(:event, fn %{step: updated_step} ->
      run = step.run || Repo.get!(Run, updated_step.run_id)

      RunEvent.changeset(%RunEvent{}, %{
        workspace_id: run.workspace_id,
        run_id: run.id,
        run_step_id: updated_step.id,
        agent_id: updated_step.assigned_agent_id,
        event_type: event_type,
        summary: summary,
        payload: %{"approval" => updated_step.approval}
      })
    end)
    |> Repo.transaction()
    |> case do
      {:ok, %{step: updated_step, event: event}} ->
        HydraAgent.Runtime.PubSub.broadcast_run_event(event)
        {:ok, updated_step}

      {:error, _operation, changeset, _changes} ->
        {:error, changeset}
    end
  end

  defp approval_attrs(%RunStep{} = step, attrs, decision) do
    attrs = stringify_keys(attrs)

    approval =
      step.approval
      |> Map.merge(%{
        "decision" => decision,
        "actor" => Map.get(attrs, "actor", "operator"),
        "reason" => Map.get(attrs, "reason", ""),
        "decided_at" => DateTime.to_iso8601(now())
      })

    %{"approval" => approval}
  end

  defp append_state_entry(state, key, entry) when is_map(state) do
    Map.update(state, key, [entry], fn entries ->
      if is_list(entries), do: entries ++ [entry], else: [entry]
    end)
  end

  defp append_state_entry(_state, key, entry), do: %{key => [entry]}

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:microsecond)

  defp put_default_capabilities(attrs) do
    attrs = stringify_keys(attrs)

    Map.put_new_lazy(attrs, "capability_profile", fn ->
      HydraAgent.Runtime.Autonomy.default_capability_profile(attrs["role"])
    end)
  end

  defp stringify_keys(map) when is_map(map) do
    Map.new(map, fn {key, value} -> {to_string(key), value} end)
  end
end
