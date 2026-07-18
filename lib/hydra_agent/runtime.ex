defmodule HydraAgent.Runtime do
  @moduledoc """
  Runtime facade for workspaces, agents, conversations, runs, policies, and providers.
  """

  import Ecto.Query

  alias Ecto.Multi
  alias HydraAgent.Repo
  alias HydraAgent.Security.WorkspaceAssociation
  alias HydraAgent.Tools.Bundles
  alias HydraAgent.Tools.Registry, as: ToolRegistry

  alias HydraAgent.Runtime.{
    AgentProfile,
    Conversation,
    CredentialPool,
    CredentialPoolItem,
    Mission,
    ProviderConfig,
    Run,
    RunEvent,
    RunStep,
    ToolPolicy,
    Turn,
    Workspace
  }

  @run_transitions %{
    "planned" => ~w(running paused blocked awaiting_approval completed failed canceled),
    "running" => ~w(paused blocked awaiting_approval completed failed canceled),
    "paused" => ~w(running failed canceled),
    "blocked" => ~w(running failed canceled),
    "awaiting_approval" => ~w(running blocked failed canceled),
    "completed" => [],
    "failed" => [],
    "canceled" => []
  }

  @step_transitions %{
    "planned" => ~w(running canceled skipped),
    "running" => ~w(planned blocked awaiting_approval completed failed canceled),
    "blocked" => ~w(planned canceled),
    "awaiting_approval" => ~w(planned canceled),
    "completed" => [],
    "failed" => [],
    "canceled" => [],
    "skipped" => []
  }

  def list_workspaces do
    Workspace |> order_by([w], asc: w.name) |> Repo.all()
  end

  def list_operator_workspaces(user), do: HydraAgent.Accounts.list_operator_workspaces(user)

  def list_workspace_ids do
    Workspace
    |> where([workspace], workspace.status == "active")
    |> select([workspace], workspace.id)
    |> Repo.all()
  end

  def get_workspace!(id), do: Repo.get!(Workspace, id)

  @doc """
  Returns the server-trusted filesystem root for a workspace.

  A configured `settings["project_root"]` wins. Relative project roots are
  resolved against the server-owned fallback rather than the process working
  directory, so callers cannot influence the filesystem authority boundary.
  """
  def trusted_workspace_root(%Workspace{} = workspace) do
    server_root = server_workspace_root!()

    (workspace.settings || %{})
    |> Map.get("project_root")
    |> normalize_workspace_root(server_root)
  end

  def trusted_workspace_root(workspace_id) do
    workspace_id
    |> get_workspace!()
    |> trusted_workspace_root()
  end

  def create_workspace(attrs) do
    %Workspace{} |> Workspace.changeset(attrs) |> Repo.insert()
  end

  defp normalize_workspace_root(root, server_root) when is_binary(root) do
    case String.trim(root) do
      "" -> server_root
      configured_root -> Path.expand(configured_root, server_root)
    end
  end

  defp normalize_workspace_root(_root, server_root), do: server_root

  defp server_workspace_root! do
    case Application.fetch_env(:hydra_agent, :server_workspace_root) do
      {:ok, root} when is_binary(root) ->
        root = String.trim(root)

        if root != "" and Path.type(root) == :absolute do
          Path.expand(root)
        else
          raise ArgumentError, ":server_workspace_root must be a non-empty absolute path"
        end

      _missing_or_invalid ->
        raise ArgumentError, ":server_workspace_root must be configured as an absolute path"
    end
  end

  def list_agents(workspace_id) do
    AgentProfile
    |> where([a], a.workspace_id == ^workspace_id)
    |> order_by([a], asc: a.name)
    |> Repo.all()
  end

  def get_agent!(id), do: Repo.get!(AgentProfile, id)

  def get_agent_by_slug(workspace_id, slug) when is_binary(slug) do
    AgentProfile
    |> where([agent], agent.workspace_id == ^workspace_id and agent.slug == ^slug)
    |> Repo.one()
  end

  def get_agent_for_workspace!(workspace_id, id) do
    AgentProfile
    |> where([agent], agent.workspace_id == ^workspace_id and agent.id == ^normalize_id(id))
    |> Repo.one!()
  end

  def list_agent_runs(workspace_id, agent_id, opts \\ []) do
    limit = opt(opts, :limit, 8)

    Run
    |> where(
      [run],
      run.workspace_id == ^workspace_id and run.supervisor_agent_id == ^normalize_id(agent_id)
    )
    |> order_by([run], desc: run.inserted_at)
    |> limit(^limit)
    |> preload([:steps, :events])
    |> Repo.all()
  end

  def list_agent_assigned_steps(workspace_id, agent_id, opts \\ []) do
    limit = opt(opts, :limit, 8)

    RunStep
    |> join(:inner, [step], run in assoc(step, :run))
    |> where(
      [step, run],
      run.workspace_id == ^workspace_id and step.assigned_agent_id == ^normalize_id(agent_id)
    )
    |> order_by([step, _run], desc: step.inserted_at)
    |> limit(^limit)
    |> preload([step, run], run: run)
    |> Repo.all()
  end

  def create_agent(attrs) do
    attrs = put_default_capabilities(attrs)
    %AgentProfile{} |> AgentProfile.changeset(attrs) |> Repo.insert()
  end

  def update_agent(%AgentProfile{} = agent, attrs) do
    agent |> AgentProfile.changeset(attrs) |> Repo.update()
  end

  def create_provider(attrs) do
    %ProviderConfig{} |> ProviderConfig.changeset(attrs) |> Repo.insert()
  end

  def list_providers(workspace_id) do
    ProviderConfig
    |> where([provider], is_nil(provider.workspace_id) or provider.workspace_id == ^workspace_id)
    |> order_by([provider], asc: provider.name)
    |> preload([:credential_pool])
    |> Repo.all()
  end

  def get_provider!(id), do: ProviderConfig |> Repo.get!(id) |> Repo.preload([:credential_pool])

  def get_provider_for_workspace!(workspace_id, id) do
    ProviderConfig
    |> where(
      [provider],
      provider.id == ^normalize_id(id) and
        (is_nil(provider.workspace_id) or provider.workspace_id == ^normalize_id(workspace_id))
    )
    |> Repo.one!()
    |> Repo.preload([:credential_pool])
  end

  def create_credential_pool(attrs) do
    attrs = stringify_keys(attrs)

    Multi.new()
    |> Multi.insert(:pool, CredentialPool.changeset(%CredentialPool{}, attrs))
    |> Multi.run(:items, fn _repo, %{pool: pool} ->
      attrs
      |> Map.get("env_vars", [])
      |> List.wrap()
      |> Enum.map(&%{"env_var" => &1, "label" => &1})
      |> create_credential_pool_items(pool)
    end)
    |> Repo.transaction()
    |> case do
      {:ok, %{pool: pool}} -> {:ok, get_credential_pool!(pool.id)}
      {:error, _operation, changeset, _changes} -> {:error, changeset}
    end
  end

  def list_credential_pools(workspace_id) do
    CredentialPool
    |> where([pool], is_nil(pool.workspace_id) or pool.workspace_id == ^workspace_id)
    |> order_by([pool], asc: pool.name)
    |> preload([:providers, :items])
    |> Repo.all()
  end

  def get_credential_pool!(id),
    do: CredentialPool |> Repo.get!(id) |> Repo.preload([:providers, :items])

  def get_credential_pool_for_workspace!(workspace_id, id) do
    CredentialPool
    |> where(
      [pool],
      pool.id == ^normalize_id(id) and
        (is_nil(pool.workspace_id) or pool.workspace_id == ^normalize_id(workspace_id))
    )
    |> Repo.one!()
    |> Repo.preload([:providers, :items])
  end

  def create_credential_pool_item(%CredentialPool{} = pool, attrs) do
    attrs =
      attrs
      |> stringify_keys()
      |> Map.put("credential_pool_id", pool.id)

    %CredentialPoolItem{} |> CredentialPoolItem.changeset(attrs) |> Repo.insert()
  end

  def list_credential_pool_items(%CredentialPool{id: pool_id}),
    do: list_credential_pool_items(pool_id)

  def list_credential_pool_items(pool_id) do
    CredentialPoolItem
    |> where([item], item.credential_pool_id == ^normalize_id(pool_id))
    |> order_by([item], asc: item.priority, asc: item.request_count, asc: item.id)
    |> Repo.all()
  end

  def next_credential_pool_item(%CredentialPool{} = pool) do
    now = now()

    CredentialPoolItem
    |> where([item], item.credential_pool_id == ^pool.id)
    |> where([item], item.status == "active")
    |> where([item], is_nil(item.cooldown_until) or item.cooldown_until <= ^now)
    |> order_by([item],
      asc: item.priority,
      asc: item.request_count,
      asc: item.last_used_at,
      asc: item.id
    )
    |> limit(1)
    |> Repo.one()
  end

  def mark_credential_pool_item_used(%CredentialPoolItem{} = item) do
    item
    |> CredentialPoolItem.changeset(%{
      "request_count" => item.request_count + 1,
      "last_used_at" => now(),
      "status" => "active",
      "last_error" => %{}
    })
    |> Repo.update()
  end

  def mark_credential_pool_item_failed(%CredentialPoolItem{} = item, error, opts \\ []) do
    cooldown_ms = Keyword.get(opts, :cooldown_ms, 60_000)
    status = if retryable_provider_error?(error), do: "cooldown", else: "exhausted"
    cooldown_until = if status == "cooldown", do: DateTime.add(now(), cooldown_ms, :millisecond)

    item
    |> CredentialPoolItem.changeset(%{
      "status" => status,
      "failure_count" => item.failure_count + 1,
      "cooldown_until" => cooldown_until,
      "last_error" => normalize_error_map(error)
    })
    |> Repo.update()
  end

  def create_tool_policy(attrs) do
    attrs = expand_tool_policy_bundles(attrs)
    %ToolPolicy{} |> ToolPolicy.changeset(attrs) |> Repo.insert()
  end

  def list_tool_policies(workspace_id) do
    ToolPolicy
    |> where([policy], policy.workspace_id == ^workspace_id)
    |> order_by([policy], desc: policy.inserted_at)
    |> Repo.all()
  end

  def get_tool_policy!(id), do: Repo.get!(ToolPolicy, id)

  def get_tool_policy_for_workspace!(workspace_id, id) do
    ToolPolicy
    |> where(
      [policy],
      policy.workspace_id == ^normalize_id(workspace_id) and policy.id == ^normalize_id(id)
    )
    |> Repo.one!()
  end

  def tool_bundles, do: Bundles.all()

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

  def list_missions(workspace_id, opts \\ []) do
    Mission
    |> where([mission], mission.workspace_id == ^workspace_id)
    |> maybe_filter_mission_status(opt(opts, :status))
    |> maybe_filter_mission_query(opt(opts, :q))
    |> order_by([mission], desc: mission.priority, desc: mission.inserted_at)
    |> limit(^opt(opts, :limit, 100))
    |> preload([:supervisor_agent])
    |> Repo.all()
  end

  def get_mission!(id) do
    Mission
    |> Repo.get!(id)
    |> Repo.preload(
      supervisor_agent: [],
      runs: from(run in Run, order_by: [desc: run.inserted_at], preload: [:supervisor_agent])
    )
  end

  def get_mission_for_workspace!(workspace_id, id) do
    Mission
    |> where(
      [mission],
      mission.workspace_id == ^normalize_id(workspace_id) and mission.id == ^normalize_id(id)
    )
    |> Repo.one!()
    |> Repo.preload(
      supervisor_agent: [],
      runs: from(run in Run, order_by: [desc: run.inserted_at], preload: [:supervisor_agent])
    )
  end

  def create_mission(attrs) do
    attrs = normalize_mission_attrs(attrs)
    %Mission{} |> Mission.changeset(attrs) |> Repo.insert()
  end

  def update_mission(%Mission{} = mission, attrs) do
    mission |> Mission.changeset(normalize_mission_attrs(attrs)) |> Repo.update()
  end

  def create_mission_run(%Mission{} = mission, attrs \\ %{}) do
    plan =
      Map.merge(
        %{
          "mission_context" => mission.context,
          "success_criteria" => mission.success_criteria,
          "team" => mission.team,
          "permissions" => mission.permissions,
          "start_mode" => mission.start_mode
        },
        Map.get(stringify_keys(attrs), "plan", %{})
      )

    attrs =
      attrs
      |> stringify_keys()
      |> Map.put("workspace_id", mission.workspace_id)
      |> Map.put("mission_id", mission.id)
      |> Map.put_new("supervisor_agent_id", mission.supervisor_agent_id)
      |> Map.put_new("title", mission.title)
      |> Map.put_new("goal", mission.objective)
      |> Map.put_new("priority", mission.priority)
      |> Map.put_new("budget", mission.budget)
      |> Map.put_new("plan", plan)

    create_run(attrs)
  end

  def start_mission(%Mission{} = mission, attrs \\ %{}) do
    attrs = stringify_keys(attrs)
    start_mode = attrs["start_mode"] || mission.start_mode || "draft"
    run_status = if start_mode == "plan_only", do: "planned", else: "running"
    mission_status = if start_mode == "plan_only", do: "planned", else: "running"

    mission_attrs =
      %{
        "status" => mission_status,
        "started_at" => mission.started_at || now(),
        "start_mode" => start_mode
      }
      |> Map.merge(Map.take(attrs, ["started_at"]))

    with {:ok, updated_mission} <- update_mission(mission, mission_attrs),
         {:ok, run} <-
           create_mission_run(
             updated_mission,
             attrs
             |> Map.put_new("status", run_status)
             |> Map.put_new("lineage_reason", "mission_start")
           ) do
      if start_mode == "start_worker" do
        HydraAgent.Agent.Supervisor.start_run_worker(run.id)
      end

      {:ok, %{mission: updated_mission, run: run}}
    end
  end

  def refresh_mission_status(nil), do: :ok

  def refresh_mission_status(mission_id) do
    mission = Repo.get(Mission, mission_id)

    if mission do
      runs =
        Run
        |> where([run], run.mission_id == ^mission.id)
        |> select([run], run.status)
        |> Repo.all()

      next_status = mission_status_from_runs(runs, mission.status)

      completed_at =
        if next_status in ["completed", "failed", "canceled"],
          do: now(),
          else: mission.completed_at

      mission
      |> Mission.changeset(%{"status" => next_status, "completed_at" => completed_at})
      |> Repo.update()
    else
      :ok
    end
  end

  def create_run(attrs) do
    attrs = stringify_keys(attrs)

    Multi.new()
    |> maybe_insert_implicit_mission(attrs)
    |> Multi.insert(:run, fn changes ->
      attrs
      |> put_implicit_mission_id(changes)
      |> then(&Run.changeset(%Run{}, &1))
    end)
    |> Multi.insert(:event, fn %{run: run} ->
      RunEvent.changeset(%RunEvent{}, %{
        workspace_id: run.workspace_id,
        run_id: run.id,
        agent_id: run.supervisor_agent_id,
        event_type: "run.created",
        summary: "Run created",
        payload: %{
          "title" => run.title,
          "autonomy_level" => run.autonomy_level,
          "mission_id" => run.mission_id,
          "parent_run_id" => run.parent_run_id,
          "lineage_type" => run.lineage_type
        }
      })
    end)
    |> Repo.transaction()
    |> case do
      {:ok, %{run: run, event: event}} ->
        HydraAgent.Runtime.PubSub.broadcast_run_event(event)
        refresh_mission_status(run.mission_id)
        run = Repo.preload(run, [:mission, :supervisor_agent, :steps, :events])
        HydraAgent.Runtime.PubSub.broadcast_run(run)
        {:ok, run}

      {:error, _operation, changeset, _changes} ->
        {:error, changeset}
    end
  end

  def retry_run(%Run{} = run, attrs \\ %{}) do
    clone_run(run, "retry", attrs)
  end

  def fork_run(%Run{} = run, attrs \\ %{}) do
    clone_run(run, "fork", attrs)
  end

  def create_run_step(%Run{} = run, attrs) do
    attrs =
      attrs
      |> stringify_keys()
      |> Map.put("run_id", run.id)

    step_changeset =
      %RunStep{}
      |> RunStep.changeset(attrs)
      |> WorkspaceAssociation.validate(:assigned_agent_id, AgentProfile,
        workspace_id: run.workspace_id
      )

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

  def list_runs(workspace_id, opts \\ []) do
    Run
    |> where([r], r.workspace_id == ^workspace_id)
    |> maybe_filter_run_status(opt(opts, :status))
    |> maybe_filter_run_mission(opt(opts, :mission_id))
    |> maybe_filter_run_query(opt(opts, :q))
    |> order_by([r], desc: r.inserted_at)
    |> limit(^opt(opts, :limit, 100))
    |> preload([:mission, :supervisor_agent, :steps, :events])
    |> Repo.all()
  end

  def get_run!(id) do
    Run
    |> Repo.get!(id)
    |> Repo.preload([:mission, :parent_run, :child_runs, :supervisor_agent, :steps, :events])
  end

  def get_run_for_workspace!(workspace_id, id) do
    Run
    |> where(
      [run],
      run.workspace_id == ^normalize_id(workspace_id) and run.id == ^normalize_id(id)
    )
    |> Repo.one!()
    |> Repo.preload([:mission, :parent_run, :child_runs, :supervisor_agent, :steps, :events])
  end

  def get_run_detail!(id) do
    Run
    |> Repo.get!(id)
    |> Repo.preload(
      mission: [],
      parent_run: [],
      child_runs: from(run in Run, order_by: [desc: run.inserted_at]),
      supervisor_agent: [],
      steps: from(step in RunStep, order_by: [asc: step.index, asc: step.id]),
      events: from(event in RunEvent, order_by: [asc: event.inserted_at, asc: event.id])
    )
  end

  def get_run_detail_for_workspace!(workspace_id, id) do
    Run
    |> where(
      [run],
      run.workspace_id == ^normalize_id(workspace_id) and run.id == ^normalize_id(id)
    )
    |> Repo.one!()
    |> Repo.preload(
      mission: [],
      parent_run: [],
      child_runs: from(run in Run, order_by: [desc: run.inserted_at]),
      supervisor_agent: [],
      steps: from(step in RunStep, order_by: [asc: step.index, asc: step.id]),
      events: from(event in RunEvent, order_by: [asc: event.inserted_at, asc: event.id])
    )
  end

  def trace_run(run_id) do
    run = get_run_detail!(run_id)
    trace_for_run(run)
  end

  def trace_run_for_workspace(workspace_id, run_id) do
    run = get_run_detail_for_workspace!(workspace_id, run_id)
    trace_for_run(run)
  end

  defp trace_for_run(run) do
    knowledge_nodes = HydraAgent.Knowledge.list_run_nodes(run.workspace_id, run.id, limit: 1_000)

    %{
      run: run,
      mission: if(Ecto.assoc_loaded?(run.mission), do: run.mission),
      parent_run: if(Ecto.assoc_loaded?(run.parent_run), do: run.parent_run),
      child_runs: if(Ecto.assoc_loaded?(run.child_runs), do: run.child_runs, else: []),
      steps: run.steps,
      events: run.events,
      knowledge_nodes: knowledge_nodes,
      memory_nodes: Enum.filter(knowledge_nodes, &(&1.type_key == "memory")),
      artifact_nodes: Enum.filter(knowledge_nodes, &(&1.type_key == "artifact")),
      graph_relationships:
        HydraAgent.Knowledge.list_run_relationships(run.workspace_id, run.id, limit: 1_000),
      safety_events:
        HydraAgent.Safety.list_events(run.workspace_id, run_id: run.id, limit: 1_000),
      checkpoints:
        HydraAgent.Tools.Checkpoints.list_records(run.workspace_id, run_id: run.id, limit: 1_000),
      usage_records:
        HydraAgent.Usage.list_records(run.workspace_id, run_id: run.id, limit: 1_000),
      usage_summary: HydraAgent.Usage.summarize(run.workspace_id, run_id: run.id)
    }
  end

  def get_run_step!(id) do
    RunStep
    |> Repo.get!(id)
    |> Repo.preload([:run, :assigned_agent])
  end

  def get_run_step_for_workspace!(workspace_id, run_id, step_id) do
    RunStep
    |> join(:inner, [step], run in assoc(step, :run))
    |> where(
      [step, run],
      run.workspace_id == ^normalize_id(workspace_id) and run.id == ^normalize_id(run_id) and
        step.id == ^normalize_id(step_id)
    )
    |> preload([step, run], [:assigned_agent, run: run])
    |> Repo.one!()
  end

  def get_run_step_for_workspace_by_id!(workspace_id, step_id) do
    RunStep
    |> join(:inner, [step], run in assoc(step, :run))
    |> where(
      [step, run],
      step.id == ^normalize_id(step_id) and run.workspace_id == ^normalize_id(workspace_id)
    )
    |> preload([step, run], run: run)
    |> Repo.one!()
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

  def list_stale_running_steps(workspace_id, opts \\ []) do
    stale_before = opt(opts, :stale_before, now())
    limit = opt(opts, :limit, 100)

    RunStep
    |> join(:inner, [step], run in assoc(step, :run))
    |> where([step, run], run.workspace_id == ^workspace_id)
    |> where([step], step.status == "running")
    |> where([step], not is_nil(step.lease_expires_at) and step.lease_expires_at < ^stale_before)
    |> order_by([step, _run], asc: step.lease_expires_at)
    |> limit(^limit)
    |> preload([step, run], [:assigned_agent, run: run])
    |> Repo.all()
  end

  def list_run_events(run_id) do
    RunEvent
    |> where([event], event.run_id == ^run_id)
    |> order_by([event], asc: event.inserted_at)
    |> Repo.all()
  end

  def run_worker_summary(run_id, lease_owner \\ nil) do
    run = get_run!(run_id)
    current_step = current_running_step(run.id, lease_owner)

    %{
      run_id: run.id,
      run_status: run.status,
      current_step_id: current_step && current_step.id,
      current_step_title: current_step && current_step.title,
      current_step_status: current_step && current_step.status,
      step_counts: step_status_counts(run.id)
    }
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
      locked_run =
        Run
        |> where([locked_run], locked_run.id == ^run.id)
        |> lock("FOR UPDATE")
        |> Repo.one!()

      unless locked_run.status in ["planned", "running"] do
        Repo.rollback({:run_not_runnable, locked_run.status})
      end

      running? =
        RunStep
        |> where([step], step.run_id == ^run.id and step.status == "running")
        |> Repo.exists?()

      step =
        if running? do
          nil
        else
          candidate =
            RunStep
            |> where([step], step.run_id == ^run.id and step.status == "planned")
            |> order_by([step], asc: step.index)
            |> lock("FOR UPDATE")
            |> limit(1)
            |> Repo.one()

          case candidate do
            nil ->
              nil

            candidate ->
              blocked_by_earlier_step? =
                RunStep
                |> where(
                  [step],
                  step.run_id == ^run.id and step.index < ^candidate.index and
                    step.status not in ["completed", "skipped"]
                )
                |> Repo.exists?()

              if blocked_by_earlier_step?, do: nil, else: candidate
          end
        end

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
      {:ok, nil} ->
        {:ok, nil}

      {:ok, step} ->
        {:ok, Repo.preload(step, [:run, :assigned_agent])}

      {:error, {:run_not_runnable, status}} ->
        {:error, %{"reason" => "run_not_runnable", "run_id" => run.id, "status" => status}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def lease_parallel_safe_steps(%Run{} = run, lease_owner, opts \\ [])
      when is_binary(lease_owner) do
    lease_ms = Keyword.get(opts, :lease_ms, 60_000)
    max_steps = opts |> Keyword.get(:max_steps, 4) |> max(1) |> min(32)
    leased_until = DateTime.add(now(), lease_ms, :millisecond)
    parallel_safe_tool_names = ToolRegistry.parallel_safe_names()

    Repo.transaction(fn ->
      locked_run =
        Run
        |> where([locked_run], locked_run.id == ^run.id)
        |> lock("FOR UPDATE")
        |> Repo.one!()

      unless locked_run.status in ["planned", "running"] do
        Repo.rollback({:run_not_runnable, locked_run.status})
      end

      remaining_steps =
        RunStep
        |> where([step], step.run_id == ^run.id)
        |> where([step], step.status not in ["completed", "skipped"])
        |> order_by([step], asc: step.index)
        |> lock("FOR UPDATE")
        |> Repo.all()

      steps =
        remaining_steps
        |> Enum.take_while(fn step ->
          step.status == "planned" and step.side_effect_class == "read_only" and
            step.tool_name in parallel_safe_tool_names
        end)
        |> Enum.take(max_steps)

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
      {:ok, steps} ->
        {:ok, Repo.preload(steps, [:run, :assigned_agent])}

      {:error, {:run_not_runnable, status}} ->
        {:error, %{"reason" => "run_not_runnable", "run_id" => run.id, "status" => status}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def heartbeat_step(%RunStep{} = step, lease_owner, opts \\ []) when is_binary(lease_owner) do
    lease_ms = Keyword.get(opts, :lease_ms, 60_000)
    heartbeat_at = now()
    leased_until = DateTime.add(heartbeat_at, lease_ms, :millisecond)

    Repo.transaction(fn ->
      current =
        RunStep
        |> where([current], current.id == ^step.id)
        |> lock("FOR UPDATE")
        |> Repo.one!()

      active? =
        current.status == "running" and current.lease_owner == lease_owner and
          not is_nil(current.lease_expires_at) and
          DateTime.compare(current.lease_expires_at, heartbeat_at) == :gt

      unless active?, do: Repo.rollback(:lease_lost)

      current
      |> RunStep.changeset(%{
        "heartbeat_at" => heartbeat_at,
        "lease_expires_at" => leased_until
      })
      |> Repo.update!()
    end)
    |> case do
      {:ok, updated_step} ->
        run = run_for_step(step, updated_step.run_id)

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

      {:error, :lease_lost} ->
        {:error, :lease_lost}

      {:error, reason} ->
        {:error, reason}
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

    next_status = Map.get(attrs, "status", step.status)

    Repo.transaction(fn ->
      current =
        RunStep
        |> where([current], current.id == ^step.id)
        |> lock("FOR UPDATE")
        |> Repo.one!()

      if step.status == "running" do
        active? =
          current.status == "running" and is_binary(step.lease_owner) and
            current.lease_owner == step.lease_owner and not is_nil(current.lease_expires_at) and
            DateTime.compare(current.lease_expires_at, now()) == :gt

        unless active?, do: Repo.rollback(:lease_lost)
      end

      with :ok <- validate_step_transition(current.status, next_status) do
        current
        |> RunStep.changeset(attrs)
        |> Repo.update!()
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
    |> unwrap_transaction()
  end

  def recover_stale_steps(workspace_id, opts \\ []) do
    stale_before = Keyword.get(opts, :stale_before, now())
    max_attempts = Keyword.get(opts, :max_attempts, 3)

    RunStep
    |> join(:inner, [step], run in assoc(step, :run))
    |> where([step, run], run.workspace_id == ^workspace_id)
    |> where([step], step.status == "running")
    |> where([step], not is_nil(step.lease_expires_at) and step.lease_expires_at < ^stale_before)
    |> select([step, _run], step.id)
    |> Repo.all()
    |> Enum.map(&recover_stale_step(&1, stale_before, max_attempts))
    |> Enum.reject(&is_nil/1)
  end

  def transition_run(%Run{} = run, status, attrs \\ %{}) do
    attrs = Map.merge(stringify_keys(attrs), %{"status" => status})

    Repo.transaction(fn ->
      current =
        Run
        |> where([current], current.id == ^run.id)
        |> lock("FOR UPDATE")
        |> Repo.one!()

      with :ok <- validate_run_transition(current.status, status) do
        current |> Run.changeset(attrs) |> Repo.update!()
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
    |> unwrap_transaction()
  end

  def start_run(%Run{} = run) do
    update_run_with_event(
      run,
      "running",
      %{"started_at" => run.started_at || now(), "completed_at" => nil},
      "run.started",
      "Run started"
    )
  end

  def pause_run(%Run{} = run, attrs \\ %{}) do
    update_run_with_event(run, "paused", attrs, "run.paused", "Run paused")
  end

  def resume_run(%Run{} = run, attrs \\ %{}) do
    attrs = Map.put(stringify_keys(attrs), "completed_at", nil)
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
    with {:ok, approved_step} <-
           transition_step_with_event(
             step,
             "planned",
             approval_attrs(step, attrs, "approved"),
             "step.approved",
             "Step approved"
           ),
         run <- Repo.get!(Run, approved_step.run_id),
         :ok <- resume_approved_run(run) do
      {:ok, approved_step}
    end
  end

  def reject_run_step(%RunStep{} = step, attrs \\ %{}) do
    with {:ok, rejected_step} <-
           transition_step_with_event(
             step,
             "canceled",
             approval_attrs(step, attrs, "rejected"),
             "step.rejected",
             "Step rejected"
           ),
         run <- Repo.get!(Run, rejected_step.run_id),
         :ok <- block_rejected_run(run, rejected_step) do
      {:ok, rejected_step}
    end
  end

  def transition_step(%RunStep{} = step, status, attrs \\ %{}) do
    attrs = Map.merge(stringify_keys(attrs), %{"status" => status})

    Repo.transaction(fn ->
      current =
        RunStep
        |> where([current], current.id == ^step.id)
        |> lock("FOR UPDATE")
        |> Repo.one!()

      with :ok <- validate_step_transition(current.status, status) do
        current |> RunStep.changeset(attrs) |> Repo.update!()
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
    |> unwrap_transaction()
  end

  defp maybe_insert_implicit_mission(multi, attrs) do
    if has_mission_id?(attrs) do
      multi
    else
      Multi.insert(multi, :mission, fn _changes ->
        Mission.changeset(%Mission{}, implicit_mission_attrs(attrs))
      end)
    end
  end

  defp put_implicit_mission_id(attrs, %{mission: %Mission{id: mission_id}}) do
    Map.put(attrs, "mission_id", mission_id)
  end

  defp put_implicit_mission_id(attrs, _changes), do: attrs

  defp implicit_mission_attrs(attrs) do
    %{
      "workspace_id" => attrs["workspace_id"],
      "supervisor_agent_id" => attrs["supervisor_agent_id"],
      "title" => attrs["title"] || "Untitled run",
      "slug" => "run-#{System.unique_integer([:positive])}",
      "objective" => attrs["goal"] || "No goal provided",
      "mission_type" => Map.get(attrs, "mission_type", "custom"),
      "status" => mission_status_for_run(Map.get(attrs, "status", "planned")),
      "priority" => Map.get(attrs, "priority", 0),
      "budget" => Map.get(attrs, "budget", %{}),
      "metadata" =>
        Map.merge(Map.get(attrs, "metadata", %{}), %{
          "created_from" => "implicit_run"
        }),
      "started_at" => attrs["started_at"],
      "completed_at" => attrs["completed_at"]
    }
  end

  defp has_mission_id?(attrs) do
    mission_id = attrs["mission_id"]
    not is_nil(mission_id) and mission_id != ""
  end

  defp mission_status_for_run(status) do
    if status in Mission.statuses(), do: status, else: "planned"
  end

  defp mission_status_from_runs([], current_status), do: current_status || "draft"

  defp mission_status_from_runs(statuses, _current_status) do
    cond do
      Enum.any?(statuses, &(&1 == "awaiting_approval")) -> "awaiting_approval"
      Enum.any?(statuses, &(&1 == "blocked")) -> "blocked"
      Enum.any?(statuses, &(&1 == "running")) -> "running"
      Enum.any?(statuses, &(&1 == "paused")) -> "paused"
      Enum.any?(statuses, &(&1 == "planned")) -> "planned"
      Enum.all?(statuses, &(&1 == "completed")) -> "completed"
      Enum.all?(statuses, &(&1 in ["failed", "canceled"])) -> "failed"
      Enum.any?(statuses, &(&1 == "failed")) -> "blocked"
      true -> "completed"
    end
  end

  defp normalize_mission_attrs(attrs) do
    attrs
    |> stringify_keys()
    |> normalize_json_map_field("success_criteria")
    |> normalize_json_map_field("context")
    |> normalize_json_map_field("team")
    |> normalize_json_map_field("permissions")
    |> normalize_json_map_field("budget")
    |> normalize_json_map_field("metadata")
  end

  defp normalize_json_map_field(attrs, key) do
    json_key = "#{key}_json"

    value =
      Map.get(attrs, key) ||
        Map.get(attrs, json_key)

    case value do
      value when is_map(value) ->
        Map.put(attrs, key, value)

      value when is_binary(value) ->
        case Jason.decode(value) do
          {:ok, decoded} when is_map(decoded) -> Map.put(attrs, key, decoded)
          _error -> attrs
        end

      _value ->
        attrs
    end
    |> Map.delete(json_key)
  end

  defp create_credential_pool_items([], _pool), do: {:ok, []}

  defp create_credential_pool_items(items, pool) do
    results =
      Enum.map(items, fn attrs ->
        create_credential_pool_item(pool, attrs)
      end)

    case Enum.find(results, &match?({:error, _changeset}, &1)) do
      {:error, changeset} -> {:error, changeset}
      nil -> {:ok, Enum.map(results, fn {:ok, item} -> item end)}
    end
  end

  defp retryable_provider_error?(%{"status" => status}) when status in [401, 402, 429], do: true
  defp retryable_provider_error?(%{"reason" => "provider_request_failed"}), do: true
  defp retryable_provider_error?(_error), do: false

  defp normalize_error_map(error) when is_map(error), do: error
  defp normalize_error_map(error), do: %{"error" => inspect(error)}

  defp clone_run(%Run{} = run, lineage_type, attrs) do
    attrs = stringify_keys(attrs)

    base_attrs = %{
      "workspace_id" => run.workspace_id,
      "mission_id" => run.mission_id,
      "supervisor_agent_id" => run.supervisor_agent_id,
      "parent_run_id" => run.id,
      "lineage_type" => lineage_type,
      "lineage_reason" => Map.get(attrs, "lineage_reason"),
      "title" => Map.get(attrs, "title", lineage_title(lineage_type, run.title)),
      "goal" => Map.get(attrs, "goal", run.goal),
      "status" => Map.get(attrs, "status", "planned"),
      "autonomy_level" => Map.get(attrs, "autonomy_level", run.autonomy_level),
      "priority" => Map.get(attrs, "priority", run.priority),
      "budget" => Map.get(attrs, "budget", run.budget),
      "plan" => Map.get(attrs, "plan", run.plan),
      "runtime_state" => %{},
      "metadata" =>
        Map.merge(Map.get(attrs, "metadata", %{}), %{
          "created_from" => lineage_type,
          "source_run_id" => run.id
        })
    }

    Repo.transaction(fn ->
      source_steps =
        RunStep
        |> where([step], step.run_id == ^run.id)
        |> order_by([step], asc: step.index)
        |> Repo.all()

      cloned_run =
        case create_run(Map.merge(base_attrs, Map.drop(attrs, ["metadata"]))) do
          {:ok, cloned_run} -> cloned_run
          {:error, reason} -> Repo.rollback(reason)
        end

      Enum.each(source_steps, fn source_step ->
        step_attrs = %{
          "assigned_agent_id" => source_step.assigned_agent_id,
          "index" => source_step.index,
          "title" => source_step.title,
          "status" => "planned",
          "tool_name" => source_step.tool_name,
          "side_effect_class" => source_step.side_effect_class,
          "input" => source_step.input,
          "output" => %{},
          "approval" => %{},
          "error" => %{},
          "attempt_count" => 0
        }

        case create_run_step(cloned_run, step_attrs) do
          {:ok, _step} -> :ok
          {:error, reason} -> Repo.rollback(reason)
        end
      end)

      get_run!(cloned_run.id)
    end)
    |> unwrap_transaction()
  end

  defp lineage_title("retry", title), do: "Retry: #{title}"
  defp lineage_title("fork", title), do: "Fork: #{title}"
  defp lineage_title(_lineage_type, title), do: title

  defp maybe_filter_mission_status(query, status) when status in [nil, "", "all"], do: query

  defp maybe_filter_mission_status(query, status),
    do: where(query, [mission], mission.status == ^status)

  defp maybe_filter_mission_query(query, q) when q in [nil, ""], do: query

  defp maybe_filter_mission_query(query, q) do
    pattern = "%#{q}%"
    where(query, [mission], ilike(mission.title, ^pattern) or ilike(mission.objective, ^pattern))
  end

  defp maybe_filter_run_status(query, status) when status in [nil, "", "all"], do: query

  defp maybe_filter_run_status(query, status),
    do: where(query, [run], run.status == ^status)

  defp maybe_filter_run_mission(query, mission_id) when mission_id in [nil, "", "all"], do: query

  defp maybe_filter_run_mission(query, mission_id),
    do: where(query, [run], run.mission_id == ^normalize_id(mission_id))

  defp maybe_filter_run_query(query, q) when q in [nil, ""], do: query

  defp maybe_filter_run_query(query, q) do
    pattern = "%#{q}%"
    where(query, [run], ilike(run.title, ^pattern) or ilike(run.goal, ^pattern))
  end

  defp update_run_with_event(run, status, attrs, event_type, summary, payload \\ %{}) do
    attrs = Map.merge(stringify_keys(attrs), %{"status" => status})

    Repo.transaction(fn ->
      current =
        Run
        |> where([current], current.id == ^run.id)
        |> lock("FOR UPDATE")
        |> Repo.one!()

      with :ok <- validate_run_transition(current.status, status) do
        updated_run = current |> Run.changeset(attrs) |> Repo.update!()

        event =
          %RunEvent{}
          |> RunEvent.changeset(%{
            workspace_id: updated_run.workspace_id,
            run_id: updated_run.id,
            agent_id: updated_run.supervisor_agent_id,
            event_type: event_type,
            summary: summary,
            payload: payload
          })
          |> Repo.insert!()

        %{run: updated_run, event: event}
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
    |> case do
      {:ok, %{run: updated_run, event: event}} ->
        HydraAgent.Runtime.PubSub.broadcast_run_event(event)
        refresh_mission_status(updated_run.mission_id)
        updated_run = Repo.preload(updated_run, [:mission, :supervisor_agent, :steps, :events])
        HydraAgent.Runtime.PubSub.broadcast_run(updated_run)
        {:ok, updated_run}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp transition_step_with_event(step, status, attrs, event_type, summary) do
    attrs = Map.merge(stringify_keys(attrs), %{"status" => status})

    Repo.transaction(fn ->
      current =
        RunStep
        |> where([current], current.id == ^step.id)
        |> lock("FOR UPDATE")
        |> Repo.one!()

      with :ok <- validate_step_transition(current.status, status) do
        updated_step = current |> RunStep.changeset(attrs) |> Repo.update!()
        run = run_for_step(step, updated_step.run_id)

        event =
          %RunEvent{}
          |> RunEvent.changeset(%{
            workspace_id: run.workspace_id,
            run_id: run.id,
            run_step_id: updated_step.id,
            agent_id: updated_step.assigned_agent_id,
            event_type: event_type,
            summary: summary,
            payload: %{"approval" => updated_step.approval}
          })
          |> Repo.insert!()

        %{step: updated_step, event: event}
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
    |> case do
      {:ok, %{step: updated_step, event: event}} ->
        HydraAgent.Runtime.PubSub.broadcast_run_event(event)
        {:ok, updated_step}

      {:error, reason} ->
        {:error, reason}
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

  defp resume_approved_run(%Run{status: "awaiting_approval"} = run) do
    with {:ok, _run} <- transition_run(run, "running", %{"completed_at" => nil}) do
      case HydraAgent.Agent.Supervisor.start_run_worker(run.id) do
        {:ok, _pid} -> :ok
        {:error, {:already_started, _pid}} -> :ok
        {:error, reason} -> {:error, {:worker_start_failed, reason}}
      end
    end
  end

  defp resume_approved_run(%Run{status: status}) when status in ["planned", "running"], do: :ok
  defp resume_approved_run(%Run{status: status}), do: {:error, {:run_not_approvable, status}}

  defp block_rejected_run(%Run{status: status} = run, rejected_step)
       when status in ["running", "awaiting_approval"] do
    case transition_run(run, "blocked", %{
           "result" => %{"reason" => "approval_rejected", "run_step_id" => rejected_step.id}
         }) do
      {:ok, _run} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp block_rejected_run(%Run{status: status}, _step) when status in ["planned", "blocked"],
    do: :ok

  defp block_rejected_run(%Run{status: status}, _step),
    do: {:error, {:run_not_rejectable, status}}

  defp append_state_entry(state, key, entry) when is_map(state) do
    Map.update(state, key, [entry], fn entries ->
      if is_list(entries), do: entries ++ [entry], else: [entry]
    end)
  end

  defp append_state_entry(_state, key, entry), do: %{key => [entry]}

  defp expand_tool_policy_bundles(attrs) do
    attrs = stringify_keys(attrs)
    bundle_names = List.wrap(attrs["tool_bundles"] || get_in(attrs, ["metadata", "tool_bundles"]))

    case Bundles.expand(bundle_names) do
      {:ok, %{"tool_bundles" => []}} ->
        attrs

      {:ok, bundle_attrs} ->
        metadata =
          attrs
          |> Map.get("metadata", %{})
          |> Map.merge(%{"tool_bundles" => bundle_attrs["tool_bundles"]})

        attrs
        |> Map.put("metadata", metadata)
        |> Map.put(
          "allowed_tools",
          Enum.uniq(List.wrap(attrs["allowed_tools"]) ++ bundle_attrs["allowed_tools"])
        )
        |> Map.put(
          "side_effect_classes",
          Enum.uniq(
            List.wrap(attrs["side_effect_classes"]) ++ bundle_attrs["side_effect_classes"]
          )
        )
        |> maybe_require_bundle_approval(bundle_attrs)

      {:error, unknown} ->
        metadata =
          attrs
          |> Map.get("metadata", %{})
          |> Map.merge(%{"unknown_tool_bundles" => unknown})

        Map.put(attrs, "metadata", metadata)
    end
  end

  defp maybe_require_bundle_approval(attrs, %{"requires_approval" => true}) do
    Map.put(attrs, "requires_approval", true)
  end

  defp maybe_require_bundle_approval(attrs, _bundle_attrs), do: attrs

  defp recover_stale_step(step_id, stale_before, max_attempts) do
    Repo.transaction(fn ->
      step =
        RunStep
        |> where(
          [step],
          step.id == ^step_id and step.status == "running" and
            not is_nil(step.lease_expires_at) and step.lease_expires_at < ^stale_before
        )
        |> lock("FOR UPDATE")
        |> Repo.one()

      if is_nil(step) do
        nil
      else
        run =
          Run
          |> where([run], run.id == ^step.run_id)
          |> lock("FOR UPDATE")
          |> Repo.one!()

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
          step
          |> RunStep.changeset(%{
            "status" => next_status,
            "error" => error,
            "completed_at" => if(next_status == "failed", do: now(), else: nil),
            "lease_owner" => nil,
            "lease_expires_at" => nil,
            "heartbeat_at" => nil
          })
          |> Repo.update()

        event_type = if next_status == "failed", do: "step.failed", else: "step.retrying"

        event =
          %RunEvent{}
          |> RunEvent.changeset(%{
            workspace_id: run.workspace_id,
            run_id: run.id,
            run_step_id: updated_step.id,
            agent_id: updated_step.assigned_agent_id,
            event_type: event_type,
            summary:
              if(next_status == "failed",
                do: "Step failed after expired lease",
                else: "Step returned to planned after expired lease"
              ),
            payload: %{"attempt_count" => step.attempt_count, "max_attempts" => max_attempts}
          })
          |> Repo.insert!()

        %{step: updated_step, run: run, event: event}
      end
    end)
    |> case do
      {:ok, nil} ->
        nil

      {:ok, %{step: step, run: run, event: event}} ->
        HydraAgent.Runtime.PubSub.broadcast_run_event(event)

        if step.status == "failed" and run.status in ["planned", "running", "paused"] do
          _ =
            fail_run(run, %{
              "result" => %{"reason" => "step_lease_expired", "run_step_id" => step.id}
            })
        end

        step

      {:error, _reason} ->
        nil
    end
  end

  defp validate_run_transition(status, status), do: :ok

  defp validate_run_transition(from, to) do
    if to in Map.get(@run_transitions, from, []) do
      :ok
    else
      {:error, {:invalid_run_transition, from, to}}
    end
  end

  defp validate_step_transition(status, status), do: :ok

  defp validate_step_transition(from, to) do
    if to in Map.get(@step_transitions, from, []) do
      :ok
    else
      {:error, {:invalid_step_transition, from, to}}
    end
  end

  defp unwrap_transaction({:ok, value}), do: {:ok, value}
  defp unwrap_transaction({:error, reason}), do: {:error, reason}

  defp run_for_step(%RunStep{run: %Run{} = run}, _run_id), do: run
  defp run_for_step(_step, run_id), do: Repo.get!(Run, run_id)

  defp current_running_step(run_id, nil) do
    RunStep
    |> where([step], step.run_id == ^run_id and step.status == "running")
    |> order_by([step], desc: step.heartbeat_at, desc: step.started_at)
    |> limit(1)
    |> Repo.one()
  end

  defp current_running_step(run_id, lease_owner) when is_binary(lease_owner) do
    RunStep
    |> where(
      [step],
      step.run_id == ^run_id and step.status == "running" and step.lease_owner == ^lease_owner
    )
    |> order_by([step], desc: step.heartbeat_at, desc: step.started_at)
    |> limit(1)
    |> Repo.one()
  end

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:microsecond)

  defp opt(opts, key, default) when is_list(opts), do: Keyword.get(opts, key, default)

  defp opt(opts, key, default) when is_map(opts),
    do: Map.get(opts, key) || Map.get(opts, to_string(key)) || default

  defp opt(opts, key) when is_list(opts), do: Keyword.get(opts, key)
  defp opt(opts, key) when is_map(opts), do: Map.get(opts, key) || Map.get(opts, to_string(key))

  defp normalize_id(id) when is_binary(id), do: String.to_integer(id)
  defp normalize_id(id), do: id

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
