defmodule HydraAgentWeb.ControlLive do
  use HydraAgentWeb, :live_view

  alias HydraAgent.{Budgets, Knowledge, Providers, Runtime, Safety, Usage}
  alias HydraAgent.Agent.Supervisor, as: AgentSupervisor
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
    socket = id |> get_run() |> Runtime.start_run() |> handle_run_result(socket, "Run started")
    {:noreply, load_workspace_state(socket)}
  end

  def handle_event("pause-run", %{"id" => id}, socket) do
    socket =
      id
      |> get_run()
      |> Runtime.pause_run(%{"actor" => "control_plane"})
      |> handle_run_result(socket, "Run paused")

    {:noreply, load_workspace_state(socket)}
  end

  def handle_event("resume-run", %{"id" => id}, socket) do
    socket =
      id
      |> get_run()
      |> Runtime.resume_run(%{"actor" => "control_plane"})
      |> handle_run_result(socket, "Run resumed")

    {:noreply, load_workspace_state(socket)}
  end

  def handle_event("cancel-run", %{"id" => id}, socket) do
    result =
      id
      |> get_run()
      |> Runtime.cancel_run(%{"actor" => "control_plane"})

    AgentSupervisor.stop_run_worker(id)

    socket = handle_run_result(result, socket, "Run canceled")
    {:noreply, load_workspace_state(socket)}
  end

  def handle_event("start-worker", %{"id" => id}, socket) do
    socket =
      case AgentSupervisor.start_run_worker(id) do
        {:ok, _pid} -> put_flash(socket, :info, "Worker started")
        {:error, {:already_started, _pid}} -> put_flash(socket, :info, "Worker already running")
        {:error, reason} -> put_flash(socket, :error, "Worker start failed: #{inspect(reason)}")
      end

    {:noreply, load_workspace_state(socket)}
  end

  def handle_event("stop-worker", %{"id" => id}, socket) do
    socket =
      case AgentSupervisor.stop_run_worker(id) do
        :ok -> put_flash(socket, :info, "Worker stopped")
        {:error, :not_found} -> put_flash(socket, :info, "No worker was running")
        {:error, reason} -> put_flash(socket, :error, "Worker stop failed: #{inspect(reason)}")
      end

    {:noreply, load_workspace_state(socket)}
  end

  def handle_event("approve-step", %{"id" => id}, socket) do
    socket =
      id
      |> get_step()
      |> Runtime.approve_run_step(%{"actor" => "control_plane"})
      |> handle_step_result(socket, "Step approved")

    {:noreply, load_workspace_state(socket)}
  end

  def handle_event("reject-step", %{"id" => id}, socket) do
    socket =
      id
      |> get_step()
      |> Runtime.reject_run_step(%{"actor" => "control_plane"})
      |> handle_step_result(socket, "Step rejected")

    {:noreply, load_workspace_state(socket)}
  end

  defp load_workspaces(socket) do
    assign(socket, :workspaces, Runtime.list_workspaces())
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
    providers = Providers.list_configs(workspace_id)
    usage = Usage.summarize(workspace_id)

    socket
    |> assign(:runs, runs)
    |> assign(:approvals, approvals)
    |> assign(:safety_events, safety_events)
    |> assign(:budget_statuses, budget_statuses)
    |> assign(:nodes, nodes)
    |> assign(:relationships, relationships)
    |> assign(:providers, providers)
    |> assign(:usage, usage)
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
    |> assign(:providers, [])
    |> assign(:usage, %{"records" => 0, "total_tokens" => 0, "by_category" => %{}})
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
  defp parse_id(id) when is_binary(id), do: String.to_integer(id)

  defp get_run(id), do: id |> parse_id() |> Runtime.get_run!()
  defp get_step(id), do: id |> parse_id() |> Runtime.get_run_step!()

  defp handle_run_result({:ok, _run}, socket, message), do: put_flash(socket, :info, message)

  defp handle_run_result({:error, changeset}, socket, _message),
    do: put_flash(socket, :error, "Run update failed: #{inspect(changeset.errors)}")

  defp handle_step_result({:ok, _step}, socket, message), do: put_flash(socket, :info, message)

  defp handle_step_result({:error, changeset}, socket, _message),
    do: put_flash(socket, :error, "Step update failed: #{inspect(changeset.errors)}")

  defp status_counts(records) do
    records
    |> Enum.frequencies_by(& &1.status)
    |> Map.put_new("running", 0)
    |> Map.put_new("awaiting_approval", 0)
    |> Map.put_new("failed", 0)
    |> Map.put_new("completed", 0)
  end

  defp latest_run(runs), do: List.first(runs)

  defp percent(nil), do: "n/a"
  defp percent(value), do: "#{Float.round(value * 100, 1)}%"

  defp timestamp(nil), do: "n/a"

  defp timestamp(datetime) do
    datetime
    |> Calendar.strftime("%m-%d %H:%M")
  end

  @impl true
  def render(assigns) do
    ~H"""
    <section id="control-plane" class="space-y-8">
      <div class="flex flex-col gap-5 border-b border-zinc-200 pb-6 lg:flex-row lg:items-end lg:justify-between">
        <div class="space-y-2">
          <p class="text-xs font-semibold uppercase tracking-[0.18em] text-zinc-500">
            Operator control
          </p>
          <h1 class="text-3xl font-semibold tracking-normal text-zinc-950">Runtime Console</h1>
          <p class="max-w-3xl text-sm leading-6 text-zinc-600">
            Durable orchestration, policy pressure, budgets, and graph state for the selected workspace.
          </p>
        </div>

        <div class="flex flex-wrap items-center gap-2">
          <.link
            :for={workspace <- @workspaces}
            patch={~p"/control?workspace_id=#{workspace.id}"}
            class={[
              "rounded-md border px-3 py-2 text-sm font-medium transition",
              workspace.id == @workspace_id && "border-zinc-950 bg-zinc-950 text-white",
              workspace.id != @workspace_id &&
                "border-zinc-200 bg-white text-zinc-700 hover:border-zinc-400"
            ]}
          >
            {workspace.name}
          </.link>
        </div>
      </div>

      <%= if @workspace_id do %>
        <div class="grid gap-4 md:grid-cols-2 xl:grid-cols-4">
          <div class="rounded-lg border border-zinc-200 bg-white p-4">
            <p class="text-xs font-semibold uppercase tracking-[0.14em] text-zinc-500">Runs</p>
            <p class="mt-3 text-3xl font-semibold text-zinc-950">{length(@runs)}</p>
            <p class="mt-1 text-sm text-zinc-600">
              {@run_counts["running"]} running / {@run_counts["awaiting_approval"]} awaiting approval
            </p>
          </div>
          <div class="rounded-lg border border-zinc-200 bg-white p-4">
            <p class="text-xs font-semibold uppercase tracking-[0.14em] text-zinc-500">Approvals</p>
            <p class="mt-3 text-3xl font-semibold text-zinc-950">{length(@approvals)}</p>
            <p class="mt-1 text-sm text-zinc-600">operator-gated steps</p>
          </div>
          <div class="rounded-lg border border-zinc-200 bg-white p-4">
            <p class="text-xs font-semibold uppercase tracking-[0.14em] text-zinc-500">Usage</p>
            <p class="mt-3 text-3xl font-semibold text-zinc-950">{@usage["total_tokens"]}</p>
            <p class="mt-1 text-sm text-zinc-600">{@usage["records"]} ledger records</p>
          </div>
          <div class="rounded-lg border border-zinc-200 bg-white p-4">
            <p class="text-xs font-semibold uppercase tracking-[0.14em] text-zinc-500">Graph</p>
            <p class="mt-3 text-3xl font-semibold text-zinc-950">{length(@nodes)}</p>
            <p class="mt-1 text-sm text-zinc-600">{length(@relationships)} recent relationships</p>
          </div>
        </div>

        <div class="grid gap-6 xl:grid-cols-[1.3fr_0.7fr]">
          <section class="space-y-3">
            <div class="flex items-center justify-between">
              <h2 class="text-lg font-semibold text-zinc-950">Runs</h2>
              <p class="text-sm text-zinc-500">
                latest: {(@runs |> latest_run() || %{inserted_at: nil}).inserted_at |> timestamp()}
              </p>
            </div>
            <div id="control-runs" class="overflow-hidden rounded-lg border border-zinc-200 bg-white">
              <div class="grid grid-cols-[72px_1fr_120px_120px_280px] border-b border-zinc-100 px-4 py-3 text-xs font-semibold uppercase tracking-[0.12em] text-zinc-500">
                <span>ID</span>
                <span>Goal</span>
                <span>Status</span>
                <span>Autonomy</span>
                <span>Actions</span>
              </div>
              <div
                :for={run <- Enum.take(@runs, 8)}
                id={"control-run-#{run.id}"}
                class="grid grid-cols-[72px_1fr_120px_120px_280px] gap-3 border-b border-zinc-100 px-4 py-3 last:border-b-0"
              >
                <span class="text-sm font-medium text-zinc-500">{run.id}</span>
                <div class="min-w-0">
                  <p class="truncate text-sm font-semibold text-zinc-950">{run.title}</p>
                  <p class="truncate text-sm text-zinc-600">{run.goal}</p>
                </div>
                <span class="text-sm text-zinc-700">{run.status}</span>
                <span class="text-sm text-zinc-700">{run.autonomy_level}</span>
                <div class="flex flex-wrap gap-2">
                  <button
                    id={"control-start-run-#{run.id}"}
                    type="button"
                    phx-click="start-run"
                    phx-value-id={run.id}
                    class="rounded-md border border-zinc-200 px-2 py-1 text-xs font-medium text-zinc-700 transition hover:border-zinc-400"
                  >
                    Start
                  </button>
                  <button
                    id={"control-pause-run-#{run.id}"}
                    type="button"
                    phx-click="pause-run"
                    phx-value-id={run.id}
                    class="rounded-md border border-zinc-200 px-2 py-1 text-xs font-medium text-zinc-700 transition hover:border-zinc-400"
                  >
                    Pause
                  </button>
                  <button
                    id={"control-resume-run-#{run.id}"}
                    type="button"
                    phx-click="resume-run"
                    phx-value-id={run.id}
                    class="rounded-md border border-zinc-200 px-2 py-1 text-xs font-medium text-zinc-700 transition hover:border-zinc-400"
                  >
                    Resume
                  </button>
                  <button
                    id={"control-cancel-run-#{run.id}"}
                    type="button"
                    phx-click="cancel-run"
                    phx-value-id={run.id}
                    class="rounded-md border border-red-200 px-2 py-1 text-xs font-medium text-red-700 transition hover:border-red-400"
                  >
                    Cancel
                  </button>
                  <button
                    id={"control-start-worker-#{run.id}"}
                    type="button"
                    phx-click="start-worker"
                    phx-value-id={run.id}
                    class="rounded-md border border-zinc-200 px-2 py-1 text-xs font-medium text-zinc-700 transition hover:border-zinc-400"
                  >
                    Worker
                  </button>
                  <button
                    id={"control-stop-worker-#{run.id}"}
                    type="button"
                    phx-click="stop-worker"
                    phx-value-id={run.id}
                    class="rounded-md border border-zinc-200 px-2 py-1 text-xs font-medium text-zinc-700 transition hover:border-zinc-400"
                  >
                    Stop
                  </button>
                </div>
              </div>
              <div :if={@runs == []} class="px-4 py-8 text-sm text-zinc-500">No runs yet.</div>
            </div>
          </section>

          <section class="space-y-3">
            <h2 class="text-lg font-semibold text-zinc-950">Approvals</h2>
            <div id="control-approvals" class="space-y-2">
              <div
                :for={step <- Enum.take(@approvals, 6)}
                id={"control-approval-#{step.id}"}
                class="rounded-lg border border-amber-200 bg-amber-50 p-4"
              >
                <p class="text-sm font-semibold text-zinc-950">{step.title}</p>
                <p class="mt-1 text-sm text-zinc-700">{step.tool_name} / {step.side_effect_class}</p>
                <div class="mt-3 flex gap-2">
                  <button
                    id={"control-approve-step-#{step.id}"}
                    type="button"
                    phx-click="approve-step"
                    phx-value-id={step.id}
                    class="rounded-md border border-emerald-200 bg-white px-2 py-1 text-xs font-medium text-emerald-700 transition hover:border-emerald-400"
                  >
                    Approve
                  </button>
                  <button
                    id={"control-reject-step-#{step.id}"}
                    type="button"
                    phx-click="reject-step"
                    phx-value-id={step.id}
                    class="rounded-md border border-red-200 bg-white px-2 py-1 text-xs font-medium text-red-700 transition hover:border-red-400"
                  >
                    Reject
                  </button>
                </div>
              </div>
              <div
                :if={@approvals == []}
                class="rounded-lg border border-zinc-200 bg-white p-4 text-sm text-zinc-500"
              >
                No pending approvals.
              </div>
            </div>
          </section>
        </div>

        <div class="grid gap-6 xl:grid-cols-3">
          <section class="space-y-3">
            <h2 class="text-lg font-semibold text-zinc-950">Safety</h2>
            <div id="control-safety" class="space-y-2">
              <div
                :for={event <- @safety_events}
                id={"control-safety-#{event.id}"}
                class="rounded-lg border border-zinc-200 bg-white p-4"
              >
                <div class="flex items-center justify-between gap-3">
                  <p class="text-sm font-semibold text-zinc-950">{event.action}</p>
                  <span class="text-xs font-medium uppercase text-zinc-500">{event.severity}</span>
                </div>
                <p class="mt-1 text-sm text-zinc-600">{event.summary}</p>
              </div>
              <div
                :if={@safety_events == []}
                class="rounded-lg border border-zinc-200 bg-white p-4 text-sm text-zinc-500"
              >
                No safety events.
              </div>
            </div>
          </section>

          <section class="space-y-3">
            <h2 class="text-lg font-semibold text-zinc-950">Budgets</h2>
            <div id="control-budgets" class="space-y-2">
              <div
                :for={budget <- @budget_statuses}
                id={"control-budget-#{budget["budget_id"]}"}
                class="rounded-lg border border-zinc-200 bg-white p-4"
              >
                <div class="flex items-center justify-between">
                  <p class="text-sm font-semibold text-zinc-950">{budget["period"]}</p>
                  <span class="text-xs font-medium uppercase text-zinc-500">{budget["status"]}</span>
                </div>
                <p class="mt-2 text-sm text-zinc-600">
                  {budget["used_tokens"]} / {budget["token_limit"] || "unbounded"} tokens
                </p>
                <p class="mt-1 text-xs text-zinc-500">{percent(budget["token_ratio"])}</p>
              </div>
              <div
                :if={@budget_statuses == []}
                class="rounded-lg border border-zinc-200 bg-white p-4 text-sm text-zinc-500"
              >
                No budgets configured.
              </div>
            </div>
          </section>

          <section class="space-y-3">
            <h2 class="text-lg font-semibold text-zinc-950">Providers</h2>
            <div id="control-providers" class="space-y-2">
              <div
                :for={provider <- @providers}
                id={"control-provider-#{provider.id}"}
                class="rounded-lg border border-zinc-200 bg-white p-4"
              >
                <p class="text-sm font-semibold text-zinc-950">{provider.name}</p>
                <p class="mt-1 text-sm text-zinc-600">{provider.kind} / {provider.model}</p>
              </div>
              <div
                :if={@providers == []}
                class="rounded-lg border border-zinc-200 bg-white p-4 text-sm text-zinc-500"
              >
                No providers configured.
              </div>
            </div>
          </section>
        </div>

        <section class="space-y-3">
          <h2 class="text-lg font-semibold text-zinc-950">Knowledge Graph</h2>
          <div id="control-graph" class="grid gap-3 md:grid-cols-2 xl:grid-cols-4">
            <div
              :for={node <- @nodes}
              id={"control-node-#{node.id}"}
              class="rounded-lg border border-zinc-200 bg-white p-4"
            >
              <p class="text-xs font-semibold uppercase tracking-[0.12em] text-zinc-500">
                {node.type_key}
              </p>
              <p class="mt-2 truncate text-sm font-semibold text-zinc-950">{node.title}</p>
              <p class="mt-1 text-xs text-zinc-500">confidence {node.confidence}</p>
            </div>
            <div
              :if={@nodes == []}
              class="rounded-lg border border-zinc-200 bg-white p-4 text-sm text-zinc-500"
            >
              No graph nodes.
            </div>
          </div>
        </section>
      <% else %>
        <div class="rounded-lg border border-zinc-200 bg-white p-8 text-sm text-zinc-500">
          No workspaces yet.
        </div>
      <% end %>
    </section>
    """
  end
end
