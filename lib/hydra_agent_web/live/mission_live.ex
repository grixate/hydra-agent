defmodule HydraAgentWeb.MissionLive do
  use HydraAgentWeb, :live_view

  alias HydraAgent.Runtime
  alias HydraAgentWeb.ControlShell

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Mission Studio")
     |> assign(:workspace_id, nil)
     |> assign(:mission, nil)
     |> assign(:mission_form, to_form(%{}, as: :mission))
     |> load_workspaces()}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    workspace_id = selected_workspace_id(socket.assigns.workspaces, params["workspace_id"])

    socket =
      socket
      |> assign(:workspace_id, workspace_id)
      |> assign(:filters, %{"q" => params["q"] || "", "status" => params["status"] || "all"})
      |> load_workspace_state(params)

    {:noreply, socket}
  end

  @impl true
  def handle_event("create-mission", %{"mission" => attrs}, socket) do
    attrs = Map.put(attrs, "workspace_id", socket.assigns.workspace_id)

    case Runtime.create_mission(attrs) do
      {:ok, mission} ->
        {:noreply,
         socket
         |> put_flash(:info, "Mission created")
         |> push_navigate(
           to: ~p"/control/missions/#{mission.id}?workspace_id=#{mission.workspace_id}"
         )}

      {:error, changeset} ->
        {:noreply,
         socket
         |> assign(:mission_form, to_form(changeset, as: :mission))
         |> put_flash(:error, "Mission could not be created")}
    end
  end

  def handle_event("update-mission", %{"mission" => attrs}, socket) do
    mission = socket.assigns.mission

    case Runtime.update_mission(mission, attrs) do
      {:ok, mission} ->
        {:noreply,
         socket
         |> put_flash(:info, "Mission updated")
         |> load_workspace_state(%{"id" => mission.id})}

      {:error, changeset} ->
        {:noreply,
         socket
         |> assign(:mission_form, to_form(changeset, as: :mission))
         |> put_flash(:error, "Mission could not be updated")}
    end
  end

  def handle_event("start-mission", %{"id" => id}, socket) do
    mission = Runtime.get_mission!(id)

    socket =
      case Runtime.start_mission(mission) do
        {:ok, _result} ->
          put_flash(socket, :info, "Mission started")

        {:error, changeset} ->
          put_flash(socket, :error, "Mission start failed: #{inspect(changeset.errors)}")
      end

    {:noreply, load_workspace_state(socket, %{"id" => id})}
  end

  def handle_event("retry-run", %{"id" => id}, socket) do
    run = Runtime.get_run!(id)
    socket = handle_run_clone(Runtime.retry_run(run), socket, "Retry created")
    {:noreply, load_workspace_state(socket, %{"id" => run.mission_id})}
  end

  def handle_event("fork-run", %{"id" => id}, socket) do
    run = Runtime.get_run!(id)
    socket = handle_run_clone(Runtime.fork_run(run), socket, "Fork created")
    {:noreply, load_workspace_state(socket, %{"id" => run.mission_id})}
  end

  defp load_workspaces(socket) do
    assign(socket, :workspaces, Runtime.list_workspaces())
  end

  defp load_workspace_state(%{assigns: %{workspace_id: nil}} = socket, _params) do
    socket
    |> assign(:missions, [])
    |> assign(:runs, [])
    |> assign(:mission, nil)
    |> assign(:agents, [])
  end

  defp load_workspace_state(%{assigns: %{workspace_id: workspace_id}} = socket, params) do
    filters = socket.assigns.filters
    missions = Runtime.list_missions(workspace_id, filters)
    runs = Runtime.list_runs(workspace_id, limit: 12)
    mission = selected_mission(params["id"], missions)

    socket
    |> assign(:missions, missions)
    |> assign(:runs, runs)
    |> assign(:mission, mission)
    |> assign(:agents, Runtime.list_agents(workspace_id))
  end

  defp selected_mission(nil, _missions), do: nil

  defp selected_mission(id, missions) do
    parsed_id = parse_id(id)

    if Enum.any?(missions, &(&1.id == parsed_id)) do
      Runtime.get_mission!(parsed_id)
    end
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

  defp mission_runs(nil), do: []
  defp mission_runs(mission), do: (Ecto.assoc_loaded?(mission.runs) && mission.runs) || []

  defp status_counts(records), do: Enum.frequencies_by(records, & &1.status)

  defp json_text(nil), do: "{}"
  defp json_text(map) when map == %{}, do: "{}"
  defp json_text(map) when is_map(map), do: Jason.encode!(map, pretty: true)
  defp json_text(_value), do: "{}"

  defp handle_run_clone({:ok, _run}, socket, message), do: put_flash(socket, :info, message)

  defp handle_run_clone({:error, changeset}, socket, _message),
    do: put_flash(socket, :error, "Run clone failed: #{inspect(changeset.errors)}")

  @impl true
  def render(assigns) do
    ~H"""
    <section id="mission-studio" class="space-y-8">
      <ControlShell.header
        active={:mission}
        description="Compose missions, start execution, and inspect retry or fork lineage across runs."
        eyebrow="Mission control"
        title="Mission Studio"
        query={@filters}
        workspaces={@workspaces}
        workspace_id={@workspace_id}
      />

      <%= if @workspace_id do %>
        <div class="grid gap-6 xl:grid-cols-[360px_1fr]">
          <aside class="space-y-4">
            <section class="rounded-lg border border-zinc-200 bg-white p-4">
              <h2 class="text-base font-semibold text-zinc-950">New Mission</h2>
              <.form
                for={@mission_form}
                id="mission-create-form"
                phx-submit="create-mission"
                class="mt-4 space-y-3"
              >
                <.input field={@mission_form[:title]} label="Title" required />
                <.input field={@mission_form[:objective]} label="Objective" type="textarea" required />
                <div class="grid grid-cols-2 gap-3">
                  <.input
                    field={@mission_form[:mission_type]}
                    label="Type"
                    type="select"
                    options={[
                      {"Custom", "custom"},
                      {"Research", "research"},
                      {"Coding", "coding"},
                      {"Analysis", "analysis"},
                      {"Monitoring", "monitoring"},
                      {"Planning", "planning"}
                    ]}
                  />
                  <.input field={@mission_form[:priority]} label="Priority" type="number" value="0" />
                </div>
                <.input
                  field={@mission_form[:start_mode]}
                  label="Start mode"
                  type="select"
                  options={[
                    {"Draft", "draft"},
                    {"Plan only", "plan_only"},
                    {"Start worker", "start_worker"}
                  ]}
                />
                <.input field={@mission_form[:deadline_at]} label="Deadline" type="datetime-local" />
                <label class="block text-sm font-semibold leading-6 text-zinc-800">
                  Success criteria JSON <textarea
                    name="mission[success_criteria_json]"
                    class="mt-2 block min-h-[5rem] w-full rounded-lg border-zinc-300 text-zinc-900 focus:border-zinc-400 focus:ring-0 sm:text-sm"
                  >{}</textarea>
                </label>
                <label class="block text-sm font-semibold leading-6 text-zinc-800">
                  Context JSON <textarea
                    name="mission[context_json]"
                    class="mt-2 block min-h-[5rem] w-full rounded-lg border-zinc-300 text-zinc-900 focus:border-zinc-400 focus:ring-0 sm:text-sm"
                  >{}</textarea>
                </label>
                <label class="block text-sm font-semibold leading-6 text-zinc-800">
                  Team JSON <textarea
                    name="mission[team_json]"
                    class="mt-2 block min-h-[4rem] w-full rounded-lg border-zinc-300 text-zinc-900 focus:border-zinc-400 focus:ring-0 sm:text-sm"
                  >{}</textarea>
                </label>
                <label class="block text-sm font-semibold leading-6 text-zinc-800">
                  Permissions JSON <textarea
                    name="mission[permissions_json]"
                    class="mt-2 block min-h-[4rem] w-full rounded-lg border-zinc-300 text-zinc-900 focus:border-zinc-400 focus:ring-0 sm:text-sm"
                  >{}</textarea>
                </label>
                <.button class="w-full">Create mission</.button>
              </.form>
            </section>

            <section class="rounded-lg border border-zinc-200 bg-white p-4">
              <div class="flex items-center justify-between gap-3">
                <h2 class="text-base font-semibold text-zinc-950">Mission Index</h2>
                <span class="text-xs font-medium text-zinc-500">{length(@missions)} shown</span>
              </div>
              <div class="mt-4 grid gap-2">
                <.link
                  patch={~p"/control/missions?workspace_id=#{@workspace_id}&status=all&q="}
                  class="text-xs font-medium text-zinc-500 hover:text-zinc-950"
                >
                  clear filters
                </.link>
              </div>
              <div id="mission-index-list" class="mt-4 space-y-2">
                <.link
                  :for={mission <- @missions}
                  id={"mission-index-#{mission.id}"}
                  patch={~p"/control/missions/#{mission.id}?workspace_id=#{@workspace_id}"}
                  class={[
                    "block rounded-lg border p-3 transition",
                    @mission && @mission.id == mission.id && "border-zinc-950 bg-zinc-950 text-white",
                    (!@mission || @mission.id != mission.id) &&
                      "border-zinc-200 bg-white text-zinc-700 hover:border-zinc-400"
                  ]}
                >
                  <div class="flex items-start justify-between gap-3">
                    <p class="min-w-0 truncate text-sm font-semibold">{mission.title}</p>
                    <span class="text-xs">{mission.status}</span>
                  </div>
                  <p class="mt-1 line-clamp-2 text-xs opacity-75">{mission.objective}</p>
                </.link>
                <div
                  :if={@missions == []}
                  class="rounded-lg border border-zinc-200 p-4 text-sm text-zinc-500"
                >
                  No missions match the current filters.
                </div>
              </div>
            </section>
          </aside>

          <main class="space-y-6">
            <section class="grid gap-4 md:grid-cols-4">
              <div
                :for={{status, count} <- status_counts(@missions)}
                class="rounded-lg border border-zinc-200 bg-white p-4"
              >
                <p class="text-xs font-semibold uppercase tracking-[0.14em] text-zinc-500">
                  {status}
                </p>
                <p class="mt-2 text-2xl font-semibold text-zinc-950">{count}</p>
              </div>
            </section>

            <%= if @mission do %>
              <section
                id={"mission-detail-#{@mission.id}"}
                class="rounded-lg border border-zinc-200 bg-white p-5"
              >
                <div class="flex flex-wrap items-start justify-between gap-4">
                  <div class="min-w-0">
                    <p class="text-xs font-semibold uppercase tracking-[0.14em] text-zinc-500">
                      {@mission.mission_type} / {@mission.status}
                    </p>
                    <h2 class="mt-2 text-2xl font-semibold text-zinc-950">{@mission.title}</h2>
                    <p class="mt-2 max-w-3xl text-sm leading-6 text-zinc-600">{@mission.objective}</p>
                  </div>
                  <div class="flex flex-wrap gap-2">
                    <button
                      id={"mission-start-#{@mission.id}"}
                      phx-click="start-mission"
                      phx-value-id={@mission.id}
                      class="rounded-md bg-zinc-950 px-3 py-2 text-sm font-medium text-white"
                    >
                      Start
                    </button>
                    <.link
                      navigate={
                        ~p"/control/runs?workspace_id=#{@workspace_id}&mission_id=#{@mission.id}"
                      }
                      class="rounded-md border border-zinc-200 px-3 py-2 text-sm font-medium text-zinc-700"
                    >
                      Runs
                    </.link>
                  </div>
                </div>

                <.form
                  :let={f}
                  for={%{}}
                  as={:mission}
                  id={"mission-update-form-#{@mission.id}"}
                  phx-submit="update-mission"
                  class="mt-6 grid gap-4 border-t border-zinc-100 pt-5 md:grid-cols-2"
                >
                  <.input field={f[:title]} label="Title" value={@mission.title} required />
                  <.input
                    field={f[:priority]}
                    label="Priority"
                    type="number"
                    value={@mission.priority}
                  />
                  <.input
                    field={f[:objective]}
                    label="Objective"
                    type="textarea"
                    value={@mission.objective}
                    required
                  />
                  <.input
                    field={f[:start_mode]}
                    label="Start mode"
                    type="select"
                    value={@mission.start_mode}
                    options={[
                      {"Draft", "draft"},
                      {"Plan only", "plan_only"},
                      {"Start worker", "start_worker"}
                    ]}
                  />
                  <label class="block text-sm font-semibold leading-6 text-zinc-800 md:col-span-2">
                    Success criteria JSON <textarea
                      name="mission[success_criteria_json]"
                      class="mt-2 block min-h-[5rem] w-full rounded-lg border-zinc-300 text-zinc-900 focus:border-zinc-400 focus:ring-0 sm:text-sm"
                    ><%= json_text(@mission.success_criteria) %></textarea>
                  </label>
                  <label class="block text-sm font-semibold leading-6 text-zinc-800 md:col-span-2">
                    Context JSON <textarea
                      name="mission[context_json]"
                      class="mt-2 block min-h-[5rem] w-full rounded-lg border-zinc-300 text-zinc-900 focus:border-zinc-400 focus:ring-0 sm:text-sm"
                    ><%= json_text(@mission.context) %></textarea>
                  </label>
                  <label class="block text-sm font-semibold leading-6 text-zinc-800">
                    Team JSON <textarea
                      name="mission[team_json]"
                      class="mt-2 block min-h-[4rem] w-full rounded-lg border-zinc-300 text-zinc-900 focus:border-zinc-400 focus:ring-0 sm:text-sm"
                    ><%= json_text(@mission.team) %></textarea>
                  </label>
                  <label class="block text-sm font-semibold leading-6 text-zinc-800">
                    Permissions JSON <textarea
                      name="mission[permissions_json]"
                      class="mt-2 block min-h-[4rem] w-full rounded-lg border-zinc-300 text-zinc-900 focus:border-zinc-400 focus:ring-0 sm:text-sm"
                    ><%= json_text(@mission.permissions) %></textarea>
                  </label>
                  <div class="md:col-span-2">
                    <.button>Save mission</.button>
                  </div>
                </.form>

                <div class="mt-6 overflow-hidden rounded-lg border border-zinc-200">
                  <div class="grid grid-cols-[1fr_120px_120px_120px] bg-zinc-50 px-4 py-3 text-xs font-semibold uppercase tracking-[0.12em] text-zinc-500">
                    <span>Run</span>
                    <span>Status</span>
                    <span>Lineage</span>
                    <span>Actions</span>
                  </div>
                  <div
                    :for={run <- mission_runs(@mission)}
                    id={"mission-run-#{run.id}"}
                    class="grid grid-cols-[1fr_120px_120px_120px] items-center gap-3 border-t border-zinc-100 px-4 py-3 text-sm"
                  >
                    <.link
                      navigate={~p"/control/runs/#{run.id}"}
                      class="min-w-0 truncate font-medium text-zinc-950"
                    >
                      {run.title}
                    </.link>
                    <span class="text-zinc-600">{run.status}</span>
                    <span class="text-zinc-600">{run.lineage_type}</span>
                    <span class="flex gap-1">
                      <button
                        id={"mission-retry-run-#{run.id}"}
                        phx-click="retry-run"
                        phx-value-id={run.id}
                        class="rounded-md border border-zinc-200 px-2 py-1 text-xs font-medium text-zinc-700"
                      >
                        Retry
                      </button>
                      <button
                        id={"mission-fork-run-#{run.id}"}
                        phx-click="fork-run"
                        phx-value-id={run.id}
                        class="rounded-md border border-zinc-200 px-2 py-1 text-xs font-medium text-zinc-700"
                      >
                        Fork
                      </button>
                    </span>
                  </div>
                  <div
                    :if={mission_runs(@mission) == []}
                    class="border-t border-zinc-100 px-4 py-8 text-sm text-zinc-500"
                  >
                    No runs have been created for this mission yet.
                  </div>
                </div>
              </section>
            <% else %>
              <section class="rounded-lg border border-zinc-200 bg-white p-8 text-sm text-zinc-500">
                Select a mission to inspect lineage, or create a new one.
              </section>
            <% end %>

            <section class="rounded-lg border border-zinc-200 bg-white p-5">
              <div class="flex items-center justify-between">
                <h2 class="text-base font-semibold text-zinc-950">Recent Runs</h2>
                <.link
                  navigate={~p"/control/runs?workspace_id=#{@workspace_id}"}
                  class="text-sm font-medium text-zinc-600"
                >
                  Open run index
                </.link>
              </div>
              <div id="mission-recent-runs" class="mt-4 grid gap-2">
                <.link
                  :for={run <- @runs}
                  navigate={~p"/control/runs/#{run.id}"}
                  class="grid grid-cols-[1fr_120px_120px] rounded-lg border border-zinc-200 px-3 py-2 text-sm"
                >
                  <span class="truncate font-medium text-zinc-950">{run.title}</span>
                  <span class="text-zinc-600">{run.status}</span>
                  <span class="text-zinc-500">{run.lineage_type}</span>
                </.link>
              </div>
            </section>
          </main>
        </div>
      <% else %>
        <section class="rounded-lg border border-zinc-200 bg-white p-8 text-sm text-zinc-500">
          No workspaces yet.
        </section>
      <% end %>
    </section>
    """
  end
end
