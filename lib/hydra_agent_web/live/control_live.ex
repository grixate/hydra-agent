defmodule HydraAgentWeb.ControlLive do
  use HydraAgentWeb, :live_view

  alias HydraAgent.{Budgets, Knowledge, MCP, Memory, Providers, Runtime, Safety, Usage}
  alias HydraAgent.Agent.Supervisor, as: AgentSupervisor
  alias HydraAgentWeb.ControlComponents
  alias HydraAgentWeb.ControlShell
  alias HydraAgent.Runtime.PubSub

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Control Plane")
     |> assign(:workspace_id, nil)
     |> assign(:subscribed_workspace_id, nil)
     |> load_workspaces()}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    workspace_id = selected_workspace_id(socket.assigns.workspaces, params["workspace_id"])

    socket =
      socket
      |> maybe_subscribe(workspace_id)
      |> assign(:workspace_id, workspace_id)
      |> load_workspace_state()

    {:noreply, socket}
  end

  @impl true
  def handle_info({:run_event, _event}, socket), do: {:noreply, load_workspace_state(socket)}
  def handle_info({:run_updated, _run}, socket), do: {:noreply, load_workspace_state(socket)}

  def handle_info({:conversation_turn, _conversation, _turn}, socket),
    do: {:noreply, load_workspace_state(socket)}

  def handle_info({:conversation_delta, _conversation, _delta}, socket), do: {:noreply, socket}

  @impl true
  def handle_event("start-run", %{"id" => id}, socket) do
    socket =
      socket
      |> get_run(id)
      |> Runtime.start_run()
      |> handle_run_result(socket, "Run started")

    {:noreply, load_workspace_state(socket)}
  end

  def handle_event("pause-run", %{"id" => id}, socket) do
    socket =
      socket
      |> get_run(id)
      |> Runtime.pause_run(%{"actor" => "control_plane"})
      |> handle_run_result(socket, "Run paused")

    {:noreply, load_workspace_state(socket)}
  end

  def handle_event("resume-run", %{"id" => id}, socket) do
    socket =
      socket
      |> get_run(id)
      |> Runtime.resume_run(%{"actor" => "control_plane"})
      |> handle_run_result(socket, "Run resumed")

    {:noreply, load_workspace_state(socket)}
  end

  def handle_event("cancel-run", %{"id" => id}, socket) do
    run = get_run(socket, id)
    result = Runtime.cancel_run(run, %{"actor" => "control_plane"})

    AgentSupervisor.stop_run_worker(run.id)

    socket = handle_run_result(result, socket, "Run canceled")
    {:noreply, load_workspace_state(socket)}
  end

  def handle_event("start-worker", %{"id" => id}, socket) do
    socket =
      case find_run(socket, id) do
        nil ->
          put_flash(socket, :error, "Run not found in this workspace")

        run ->
          case AgentSupervisor.start_run_worker(run.id) do
            {:ok, _pid} ->
              put_flash(socket, :info, "Worker started")

            {:error, {:already_started, _pid}} ->
              put_flash(socket, :info, "Worker already running")

            {:error, reason} ->
              put_flash(
                socket,
                :error,
                HydraAgentWeb.UserError.message("start the worker", reason)
              )
          end
      end

    {:noreply, load_workspace_state(socket)}
  end

  def handle_event("stop-worker", %{"id" => id}, socket) do
    socket =
      case find_run(socket, id) do
        nil ->
          put_flash(socket, :error, "Run not found in this workspace")

        run ->
          case AgentSupervisor.stop_run_worker(run.id) do
            :ok ->
              put_flash(socket, :info, "Worker stopped")

            {:error, :not_found} ->
              put_flash(socket, :info, "No worker was running")

            {:error, reason} ->
              put_flash(
                socket,
                :error,
                HydraAgentWeb.UserError.message("stop the worker", reason)
              )
          end
      end

    {:noreply, load_workspace_state(socket)}
  end

  def handle_event("approve-step", %{"id" => id}, socket) do
    socket =
      socket
      |> get_step(id)
      |> Runtime.approve_run_step(%{"actor" => "control_plane"})
      |> handle_step_result(socket, "Step approved")

    {:noreply, load_workspace_state(socket)}
  end

  def handle_event("reject-step", %{"id" => id}, socket) do
    socket =
      socket
      |> get_step(id)
      |> Runtime.reject_run_step(%{"actor" => "control_plane"})
      |> handle_step_result(socket, "Step rejected")

    {:noreply, load_workspace_state(socket)}
  end

  def handle_event("promote-memory", %{"id" => id}, socket) do
    with_scoped_memory(socket, id, "Memory promoted", fn node ->
      Memory.promote_proposal(node, %{"actor" => "control_plane"})
    end)
  end

  def handle_event("reject-memory", %{"id" => id}, socket) do
    with_scoped_memory(socket, id, "Memory rejected", fn node ->
      Memory.reject_proposal(node, %{"actor" => "control_plane"})
    end)
  end

  def handle_event(
        "review-memory",
        %{"decision" => decision, "proposal_id" => id} = params,
        socket
      )
      when decision in ["promote", "reject"] do
    attrs = %{"actor" => "control_plane", "reason" => Map.get(params, "reason", "")}

    message = if decision == "promote", do: "Memory promoted", else: "Memory rejected"

    with_scoped_memory(socket, id, message, fn node ->
      case decision do
        "promote" -> Memory.promote_proposal(node, attrs)
        "reject" -> Memory.reject_proposal(node, attrs)
      end
    end)
  end

  defp load_workspaces(socket) do
    assign(socket, :workspaces, Runtime.list_operator_workspaces(socket.assigns[:current_user]))
  end

  defp load_workspace_state(%{assigns: %{workspace_id: nil}} = socket) do
    assign_empty(socket)
  end

  defp load_workspace_state(%{assigns: %{workspace_id: workspace_id}} = socket) do
    runs = Runtime.list_runs(workspace_id)
    approvals = Runtime.list_awaiting_approval_steps(workspace_id)
    safety_events = Safety.list_events(workspace_id, limit: 8)
    budget_statuses = Budgets.list_budget_statuses(workspace_id)
    nodes = Knowledge.list_nodes(workspace_id, limit: 8)
    relationships = Knowledge.list_relationships(workspace_id, limit: 8)
    memory_proposals = Memory.list_proposals(workspace_id, limit: 6)
    providers = Providers.list_configs(workspace_id)
    tool_bundles = Runtime.tool_bundles()
    tool_policies = Runtime.list_tool_policies(workspace_id)
    mcp_servers = MCP.list_servers(workspace_id)
    usage = Usage.summarize(workspace_id)

    worker_statuses =
      Map.new(runs, fn run -> {run.id, AgentSupervisor.run_worker_status(run.id)} end)

    socket
    |> assign(:runs, runs)
    |> assign(:approvals, approvals)
    |> assign(:safety_events, safety_events)
    |> assign(:budget_statuses, budget_statuses)
    |> assign(:nodes, nodes)
    |> assign(:relationships, relationships)
    |> assign(:memory_proposals, memory_proposals)
    |> assign(:providers, providers)
    |> assign(:tool_bundles, tool_bundles)
    |> assign(:tool_policies, tool_policies)
    |> assign(:mcp_servers, mcp_servers)
    |> assign(:usage, usage)
    |> assign(:worker_statuses, worker_statuses)
    |> assign(:run_counts, status_counts(runs))
  end

  defp assign_empty(socket) do
    socket
    |> assign(:runs, [])
    |> assign(:approvals, [])
    |> assign(:safety_events, [])
    |> assign(:budget_statuses, [])
    |> assign(:nodes, [])
    |> assign(:relationships, [])
    |> assign(:memory_proposals, [])
    |> assign(:providers, [])
    |> assign(:tool_bundles, [])
    |> assign(:tool_policies, [])
    |> assign(:mcp_servers, [])
    |> assign(:usage, %{"records" => 0, "total_tokens" => 0, "by_category" => %{}})
    |> assign(:worker_statuses, %{})
    |> assign(:run_counts, %{})
  end

  defp maybe_subscribe(socket, nil), do: socket

  defp maybe_subscribe(
         %{assigns: %{subscribed_workspace_id: workspace_id}} = socket,
         workspace_id
       ),
       do: socket

  defp maybe_subscribe(socket, workspace_id) do
    if connected?(socket), do: PubSub.subscribe_workspace(workspace_id)
    assign(socket, :subscribed_workspace_id, workspace_id)
  end

  defp selected_workspace_id([], _param), do: nil

  defp selected_workspace_id(workspaces, nil), do: workspaces |> List.first() |> Map.get(:id)

  defp selected_workspace_id(workspaces, workspace_id) do
    parsed_id = parse_id(workspace_id)

    if Enum.any?(workspaces, &(&1.id == parsed_id)) do
      parsed_id
    else
      workspaces |> List.first() |> Map.get(:id)
    end
  end

  defp parse_id(id) when is_integer(id), do: id

  defp parse_id(id) when is_binary(id) do
    case Integer.parse(id) do
      {parsed, ""} -> parsed
      _other -> nil
    end
  end

  defp parse_id(_id), do: nil

  defp get_run(socket, id),
    do: Runtime.get_run_for_workspace!(socket.assigns.workspace_id, parse_id(id))

  defp find_run(socket, id) do
    parsed_id = parse_id(id)
    Enum.find(socket.assigns.runs, &(&1.id == parsed_id))
  end

  defp get_step(socket, id),
    do:
      Runtime.get_run_step_for_workspace_by_id!(
        socket.assigns.workspace_id,
        parse_id(id)
      )

  defp handle_run_result({:ok, _run}, socket, message), do: put_flash(socket, :info, message)

  defp handle_run_result({:error, changeset}, socket, _message),
    do: put_flash(socket, :error, HydraAgentWeb.UserError.message("update the run", changeset))

  defp handle_step_result({:ok, _step}, socket, message), do: put_flash(socket, :info, message)

  defp handle_step_result({:error, changeset}, socket, _message),
    do: put_flash(socket, :error, HydraAgentWeb.UserError.message("update the step", changeset))

  defp handle_memory_result({:ok, _node}, socket, message), do: put_flash(socket, :info, message)

  defp handle_memory_result({:error, %{} = error}, socket, _message),
    do: put_flash(socket, :error, HydraAgentWeb.UserError.message("update memory", error))

  defp with_scoped_memory(socket, id, message, callback) do
    case Knowledge.get_node_for_workspace(socket.assigns.workspace_id, parse_id(id)) do
      nil ->
        {:noreply, put_flash(socket, :error, "Memory not found in this workspace")}

      node ->
        socket = node |> callback.() |> handle_memory_result(socket, message)
        {:noreply, load_workspace_state(socket)}
    end
  end

  defp status_counts(records) do
    records
    |> Enum.frequencies_by(& &1.status)
    |> Map.put_new("running", 0)
    |> Map.put_new("awaiting_approval", 0)
    |> Map.put_new("failed", 0)
    |> Map.put_new("completed", 0)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <section id="control-plane" class="space-y-8">
      <ControlShell.header
        active={:overview}
        description="Durable runs, approvals, budgets, and knowledge for the selected workspace."
        eyebrow="Operator control"
        title="Runtime console"
        workspaces={@workspaces}
        workspace_id={@workspace_id}
      />

      <%= if @workspace_id do %>
        <ControlComponents.metrics
          runs={@runs}
          run_counts={@run_counts}
          approvals={@approvals}
          usage={@usage}
          nodes={@nodes}
          relationships={@relationships}
        />

        <div class="grid min-w-0 gap-6 xl:grid-cols-[1.3fr_0.7fr]">
          <ControlComponents.runs_panel runs={@runs} worker_statuses={@worker_statuses} />
          <ControlComponents.approvals_panel approvals={@approvals} />
        </div>

        <ControlComponents.operations_grid
          safety_events={@safety_events}
          budget_statuses={@budget_statuses}
          providers={@providers}
          tool_bundles={@tool_bundles}
          tool_policies={@tool_policies}
          mcp_servers={@mcp_servers}
        />

        <ControlComponents.knowledge_graph
          memory_proposals={@memory_proposals}
          nodes={@nodes}
          relationships={@relationships}
        />
      <% else %>
        <ControlComponents.empty_state />
      <% end %>
    </section>
    """
  end
end
