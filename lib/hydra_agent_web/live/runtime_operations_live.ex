defmodule HydraAgentWeb.RuntimeOperationsLive do
  use HydraAgentWeb, :live_view

  alias HydraAgent.{Providers, Runtime, Safety}
  alias HydraAgent.Agent.Supervisor, as: AgentSupervisor
  alias HydraAgentWeb.ControlShell

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Runtime Operations")
     |> assign(:workspace_id, nil)
     |> load_workspaces()}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    workspace_id = selected_workspace_id(socket.assigns.workspaces, params["workspace_id"])

    socket =
      socket
      |> assign(:workspace_id, workspace_id)
      |> load_workspace_state()

    {:noreply, socket}
  end

  defp load_workspaces(socket) do
    assign(socket, :workspaces, Runtime.list_workspaces())
  end

  defp load_workspace_state(%{assigns: %{workspace_id: nil}} = socket) do
    socket
    |> assign(:runs, [])
    |> assign(:run_counts, %{})
    |> assign(:worker_statuses, [])
    |> assign(:stale_steps, [])
    |> assign(:awaiting_steps, [])
    |> assign(:providers, [])
    |> assign(:runtime_events, [])
    |> assign(:node_status, node_status())
  end

  defp load_workspace_state(%{assigns: %{workspace_id: workspace_id}} = socket) do
    runs = Runtime.list_runs(workspace_id)
    worker_statuses = Enum.map(runs, &AgentSupervisor.run_worker_status(&1.id))

    socket
    |> assign(:runs, runs)
    |> assign(:run_counts, status_counts(runs))
    |> assign(:worker_statuses, worker_statuses)
    |> assign(:stale_steps, Runtime.list_stale_running_steps(workspace_id, limit: 10))
    |> assign(:awaiting_steps, Runtime.list_awaiting_approval_steps(workspace_id))
    |> assign(:providers, Providers.list_configs(workspace_id))
    |> assign(:runtime_events, Safety.list_events(workspace_id, category: "runtime", limit: 8))
    |> assign(:node_status, node_status())
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

  defp status_counts(records), do: Enum.frequencies_by(records, & &1.status)

  defp active_worker_count(statuses), do: Enum.count(statuses, & &1.active)

  defp node_status do
    %{
      node: Atom.to_string(node()),
      otp_release: :erlang.system_info(:otp_release) |> List.to_string(),
      process_count: :erlang.system_info(:process_count),
      process_limit: :erlang.system_info(:process_limit),
      schedulers: :erlang.system_info(:schedulers_online)
    }
  end

  defp timestamp(nil), do: "n/a"
  defp timestamp(datetime), do: Calendar.strftime(datetime, "%m-%d %H:%M:%S")

  defp provider_route(provider) do
    fallback = get_in(provider.metadata || %{}, ["fallback_providers"]) || []

    if fallback == [] do
      provider.name
    else
      "#{provider.name} -> #{Enum.join(fallback, " -> ")}"
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <section id="runtime-operations" class="space-y-8">
      <ControlShell.header
        active={:runtime}
        description="Worker health, queue pressure, stale leases, provider routes, and runtime incidents for the selected workspace."
        eyebrow="Operations"
        title="Runtime Operations"
        workspaces={@workspaces}
        workspace_id={@workspace_id}
      />

      <%= if @workspace_id do %>
        <div class="grid gap-4 md:grid-cols-2 xl:grid-cols-4">
          <div class="rounded-lg border border-zinc-200 bg-white p-4">
            <p class="text-xs font-semibold uppercase tracking-[0.14em] text-zinc-500">Workers</p>
            <p class="mt-3 text-3xl font-semibold text-zinc-950">
              {active_worker_count(@worker_statuses)}
            </p>
            <p class="mt-1 text-sm text-zinc-600">{length(@worker_statuses)} tracked runs</p>
          </div>
          <div class="rounded-lg border border-zinc-200 bg-white p-4">
            <p class="text-xs font-semibold uppercase tracking-[0.14em] text-zinc-500">Queue</p>
            <p class="mt-3 text-3xl font-semibold text-zinc-950">
              {Map.get(@run_counts, "planned", 0) + Map.get(@run_counts, "running", 0)}
            </p>
            <p class="mt-1 text-sm text-zinc-600">
              {Map.get(@run_counts, "awaiting_approval", 0)} awaiting approval
            </p>
          </div>
          <div class="rounded-lg border border-zinc-200 bg-white p-4">
            <p class="text-xs font-semibold uppercase tracking-[0.14em] text-zinc-500">Recovery</p>
            <p class="mt-3 text-3xl font-semibold text-zinc-950">{length(@stale_steps)}</p>
            <p class="mt-1 text-sm text-zinc-600">expired running leases</p>
          </div>
          <div class="rounded-lg border border-zinc-200 bg-white p-4">
            <p class="text-xs font-semibold uppercase tracking-[0.14em] text-zinc-500">Node</p>
            <p class="mt-3 truncate text-2xl font-semibold text-zinc-950">{@node_status.node}</p>
            <p class="mt-1 text-sm text-zinc-600">
              {@node_status.process_count} / {@node_status.process_limit} processes
            </p>
          </div>
        </div>

        <div class="grid gap-6 xl:grid-cols-[1.1fr_0.9fr]">
          <section class="space-y-3">
            <h2 class="text-lg font-semibold text-zinc-950">Workers</h2>
            <div
              id="runtime-workers"
              class="overflow-hidden rounded-lg border border-zinc-200 bg-white"
            >
              <div class="grid grid-cols-[72px_110px_1fr_160px_120px] border-b border-zinc-100 px-4 py-3 text-xs font-semibold uppercase tracking-[0.12em] text-zinc-500">
                <span>Run</span>
                <span>Worker</span>
                <span>Current Step</span>
                <span>Heartbeat</span>
                <span>Steps</span>
              </div>
              <div
                :for={status <- Enum.take(@worker_statuses, 12)}
                id={"runtime-worker-#{status.run_id}"}
                class="grid grid-cols-[72px_110px_1fr_160px_120px] gap-3 border-b border-zinc-100 px-4 py-3 text-sm last:border-b-0"
              >
                <span class="font-medium text-zinc-500">{status.run_id}</span>
                <span class={
                  if status.active, do: "font-medium text-emerald-700", else: "text-zinc-500"
                }>
                  {if status.active, do: "active", else: "idle"}
                </span>
                <span class="truncate text-zinc-700">
                  {status.current_step_title || "no active step"}
                </span>
                <span class="text-zinc-500">{timestamp(Map.get(status, :last_heartbeat_at))}</span>
                <span class="text-zinc-500">{inspect(status.step_counts)}</span>
              </div>
              <div :if={@worker_statuses == []} class="px-4 py-8 text-sm text-zinc-500">
                No runs tracked yet.
              </div>
            </div>
          </section>

          <section class="space-y-3">
            <h2 class="text-lg font-semibold text-zinc-950">Stale Leases</h2>
            <div id="runtime-stale-steps" class="space-y-2">
              <div
                :for={step <- @stale_steps}
                id={"runtime-stale-step-#{step.id}"}
                class="rounded-lg border border-amber-200 bg-amber-50 p-4"
              >
                <p class="text-sm font-semibold text-zinc-950">{step.title}</p>
                <p class="mt-1 text-sm text-zinc-700">{step.run.title}</p>
                <p class="mt-2 text-xs text-zinc-500">
                  lease expired {timestamp(step.lease_expires_at)} / attempts {step.attempt_count}
                </p>
              </div>
              <div
                :if={@stale_steps == []}
                class="rounded-lg border border-zinc-200 bg-white p-4 text-sm text-zinc-500"
              >
                No stale running step leases.
              </div>
            </div>
          </section>
        </div>

        <div class="grid gap-6 xl:grid-cols-3">
          <section class="space-y-3">
            <h2 class="text-lg font-semibold text-zinc-950">Approvals Queue</h2>
            <div id="runtime-approval-queue" class="space-y-2">
              <div
                :for={step <- Enum.take(@awaiting_steps, 6)}
                id={"runtime-awaiting-step-#{step.id}"}
                class="rounded-lg border border-zinc-200 bg-white p-4"
              >
                <p class="text-sm font-semibold text-zinc-950">{step.title}</p>
                <p class="mt-1 text-xs text-zinc-500">{step.run.title}</p>
              </div>
              <div
                :if={@awaiting_steps == []}
                class="rounded-lg border border-zinc-200 bg-white p-4 text-sm text-zinc-500"
              >
                No steps awaiting approval.
              </div>
            </div>
          </section>

          <section class="space-y-3">
            <h2 class="text-lg font-semibold text-zinc-950">Providers</h2>
            <div id="runtime-providers" class="space-y-2">
              <div
                :for={provider <- @providers}
                id={"runtime-provider-#{provider.id}"}
                class="rounded-lg border border-zinc-200 bg-white p-4"
              >
                <p class="text-sm font-semibold text-zinc-950">{provider.name}</p>
                <p class="mt-1 text-sm text-zinc-600">{provider.kind} / {provider.model}</p>
                <p class="mt-2 text-xs text-zinc-500">route {provider_route(provider)}</p>
              </div>
              <div
                :if={@providers == []}
                class="rounded-lg border border-zinc-200 bg-white p-4 text-sm text-zinc-500"
              >
                No enabled providers.
              </div>
            </div>
          </section>

          <section class="space-y-3">
            <h2 class="text-lg font-semibold text-zinc-950">Runtime Incidents</h2>
            <div id="runtime-incidents" class="space-y-2">
              <div
                :for={event <- @runtime_events}
                id={"runtime-incident-#{event.id}"}
                class="rounded-lg border border-zinc-200 bg-white p-4"
              >
                <div class="flex items-start justify-between gap-3">
                  <p class="text-sm font-semibold text-zinc-950">{event.action}</p>
                  <span class="text-xs font-medium uppercase text-zinc-500">{event.severity}</span>
                </div>
                <p class="mt-1 text-sm text-zinc-600">{event.summary}</p>
              </div>
              <div
                :if={@runtime_events == []}
                class="rounded-lg border border-zinc-200 bg-white p-4 text-sm text-zinc-500"
              >
                No runtime incidents.
              </div>
            </div>
          </section>
        </div>

        <section class="space-y-3">
          <h2 class="text-lg font-semibold text-zinc-950">Supervisor Topology</h2>
          <div id="runtime-topology" class="grid gap-3 md:grid-cols-3">
            <div class="rounded-lg border border-zinc-200 bg-white p-4">
              <p class="text-sm font-semibold text-zinc-950">HydraAgent.Agent.Supervisor</p>
              <p class="mt-2 text-xs text-zinc-500">dynamic supervisor / one_for_one</p>
            </div>
            <div class="rounded-lg border border-zinc-200 bg-white p-4">
              <p class="text-sm font-semibold text-zinc-950">HydraAgent.Runtime.RecoveryWorker</p>
              <p class="mt-2 text-xs text-zinc-500">lease recovery loop</p>
            </div>
            <div class="rounded-lg border border-zinc-200 bg-white p-4">
              <p class="text-sm font-semibold text-zinc-950">OTP {@node_status.otp_release}</p>
              <p class="mt-2 text-xs text-zinc-500">{@node_status.schedulers} online schedulers</p>
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
