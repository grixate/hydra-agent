defmodule HydraAgentWeb.RunIndexLive do
  use HydraAgentWeb, :live_view

  alias HydraAgent.Runtime
  alias HydraAgent.Loops
  alias HydraAgentWeb.ControlShell

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Run Index")
     |> assign(:workspace_id, nil)
     |> load_workspaces()}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    workspace_id = selected_workspace_id(socket.assigns.workspaces, params["workspace_id"])

    socket =
      socket
      |> assign(:workspace_id, workspace_id)
      |> assign(:filters, %{
        "q" => params["q"] || "",
        "status" => params["status"] || "all",
        "mission_id" => params["mission_id"] || "all",
        "loop_id" => params["loop_id"] || "all"
      })
      |> load_workspace_state()

    {:noreply, socket}
  end

  defp load_workspaces(socket) do
    assign(socket, :workspaces, Runtime.list_workspaces())
  end

  defp load_workspace_state(%{assigns: %{workspace_id: nil}} = socket) do
    socket
    |> assign(:runs, [])
    |> assign(:missions, [])
    |> assign(:loops, [])
  end

  defp load_workspace_state(%{assigns: %{workspace_id: workspace_id, filters: filters}} = socket) do
    socket
    |> assign(:runs, Runtime.list_runs(workspace_id, filters))
    |> assign(:missions, Runtime.list_missions(workspace_id, limit: 500))
    |> assign(:loops, Loops.list_loops(workspace_id, limit: 500))
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

  defp mission_title(run) do
    if Ecto.assoc_loaded?(run.mission) and run.mission do
      run.mission.title
    else
      "Unassigned"
    end
  end

  defp loop_title(run) do
    if Ecto.assoc_loaded?(run.loop) and run.loop do
      run.loop.name
    else
      "No loop"
    end
  end

  defp selected?(value, value), do: true
  defp selected?(_left, _right), do: false

  @impl true
  def render(assigns) do
    ~H"""
    <section id="run-index" class="space-y-8">
      <ControlShell.header
        active={:runtime}
        description="Search runs by mission, status, title, or goal, then jump into trace and execution details."
        eyebrow="Operations"
        title="Run Index"
        query={@filters}
        workspaces={@workspaces}
        workspace_id={@workspace_id}
      />

      <%= if @workspace_id do %>
        <section class="rounded-lg border border-zinc-200 bg-white p-4">
          <form
            method="get"
            action={~p"/control/runs"}
            class="grid gap-3 md:grid-cols-[1fr_160px_200px_200px_auto]"
          >
            <input type="hidden" name="workspace_id" value={@workspace_id} />
            <input
              name="q"
              value={@filters["q"]}
              placeholder="Search title or goal"
              class="rounded-md border border-zinc-200 px-3 py-2 text-sm"
            />
            <select name="status" class="rounded-md border border-zinc-200 px-3 py-2 text-sm">
              <option value="all" selected={selected?(@filters["status"], "all")}>
                All statuses
              </option>
              <option value="planned" selected={selected?(@filters["status"], "planned")}>
                Planned
              </option>
              <option value="running" selected={selected?(@filters["status"], "running")}>
                Running
              </option>
              <option
                value="awaiting_approval"
                selected={selected?(@filters["status"], "awaiting_approval")}
              >
                Awaiting approval
              </option>
              <option value="completed" selected={selected?(@filters["status"], "completed")}>
                Completed
              </option>
              <option value="failed" selected={selected?(@filters["status"], "failed")}>
                Failed
              </option>
              <option value="canceled" selected={selected?(@filters["status"], "canceled")}>
                Canceled
              </option>
            </select>
            <select name="mission_id" class="rounded-md border border-zinc-200 px-3 py-2 text-sm">
              <option value="all" selected={selected?(@filters["mission_id"], "all")}>
                All missions
              </option>
              <option
                :for={mission <- @missions}
                value={mission.id}
                selected={selected?(@filters["mission_id"], Integer.to_string(mission.id))}
              >
                {mission.title}
              </option>
            </select>
            <select name="loop_id" class="rounded-md border border-zinc-200 px-3 py-2 text-sm">
              <option value="all" selected={selected?(@filters["loop_id"], "all")}>
                All loops
              </option>
              <option
                :for={loop <- @loops}
                value={loop.id}
                selected={selected?(@filters["loop_id"], Integer.to_string(loop.id))}
              >
                {loop.name}
              </option>
            </select>
            <button class="rounded-md bg-zinc-950 px-4 py-2 text-sm font-medium text-white">
              Search
            </button>
          </form>
        </section>

        <section class="overflow-hidden rounded-lg border border-zinc-200 bg-white">
          <div class="grid grid-cols-[1fr_180px_180px_110px_110px_100px] bg-zinc-50 px-4 py-3 text-xs font-semibold uppercase tracking-[0.12em] text-zinc-500">
            <span>Run</span>
            <span>Mission</span>
            <span>Loop</span>
            <span>Status</span>
            <span>Lineage</span>
            <span>Trace</span>
          </div>
          <div
            :for={run <- @runs}
            id={"run-index-row-#{run.id}"}
            class="grid grid-cols-[1fr_180px_180px_110px_110px_100px] items-center gap-3 border-t border-zinc-100 px-4 py-3 text-sm"
          >
            <.link navigate={~p"/control/runs/#{run.id}"} class="min-w-0">
              <span class="block truncate font-medium text-zinc-950">{run.title}</span>
              <span class="block truncate text-xs text-zinc-500">{run.goal}</span>
            </.link>
            <span class="truncate text-zinc-600">{mission_title(run)}</span>
            <span class="truncate text-zinc-600">{loop_title(run)}</span>
            <span class="text-zinc-600">{run.status}</span>
            <span class="text-zinc-600">{run.lineage_type}</span>
            <a
              href={~p"/api/v1/runs/#{run.id}/trace"}
              class="rounded-md border border-zinc-200 px-3 py-2 text-center text-xs font-medium text-zinc-700"
            >
              JSON
            </a>
          </div>
          <div :if={@runs == []} class="border-t border-zinc-100 px-4 py-10 text-sm text-zinc-500">
            No runs match the current filters.
          </div>
        </section>
      <% else %>
        <section class="rounded-lg border border-zinc-200 bg-white p-8 text-sm text-zinc-500">
          No workspaces yet.
        </section>
      <% end %>
    </section>
    """
  end
end
