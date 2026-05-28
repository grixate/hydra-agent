defmodule HydraAgentWeb.AgentDirectoryLive do
  use HydraAgentWeb, :live_view

  alias HydraAgent.{Runtime, Skills}
  alias HydraAgentWeb.ControlShell

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Agent Directory")
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
    |> assign(:agents, [])
    |> assign(:runs_by_agent, %{})
    |> assign(:skills_by_agent, %{})
    |> assign(:policies_by_agent, %{})
  end

  defp load_workspace_state(%{assigns: %{workspace_id: workspace_id}} = socket) do
    agents = Runtime.list_agents(workspace_id)
    runs_by_agent = agent_group(Runtime.list_runs(workspace_id), :supervisor_agent_id)
    skills_by_agent = agent_group(Skills.list_skills(workspace_id), :owner_agent_id)
    policies_by_agent = agent_group(Runtime.list_tool_policies(workspace_id), :agent_id)

    socket
    |> assign(:agents, agents)
    |> assign(:runs_by_agent, runs_by_agent)
    |> assign(:skills_by_agent, skills_by_agent)
    |> assign(:policies_by_agent, policies_by_agent)
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

  defp agent_group(records, field) do
    records
    |> Enum.reject(&(Map.get(&1, field) == nil))
    |> Enum.group_by(&Map.get(&1, field))
  end

  defp capability(agent, key), do: get_in(agent.capability_profile || %{}, [key]) || []

  defp approval_mode(agent),
    do:
      get_in(agent.capability_profile || %{}, ["approval_policy", "mode"]) ||
        "required_for_sensitive"

  defp max_autonomy(agent),
    do: get_in(agent.capability_profile || %{}, ["max_autonomy_level"]) || "recommend"

  defp model_value(agent, key), do: get_in(agent.model_route || %{}, [key]) || "default"

  defp status_counts(records) do
    records
    |> Enum.frequencies_by(& &1.status)
    |> Enum.sort()
  end

  defp join_or_none([]), do: "none"
  defp join_or_none(values), do: Enum.join(values, ", ")

  @impl true
  def render(assigns) do
    ~H"""
    <section id="agent-directory" class="space-y-8">
      <ControlShell.header
        active={:agents}
        description="Inspect active agents, model routes, skills, memory scopes, policies, and recent mission load."
        eyebrow="Mission control"
        title="Agent Directory"
        workspaces={@workspaces}
        workspace_id={@workspace_id}
      />

      <%= if @workspace_id do %>
        <div id="agent-directory-list" class="grid gap-4 xl:grid-cols-2">
          <article
            :for={agent <- @agents}
            id={"agent-card-#{agent.id}"}
            class="rounded-lg border border-zinc-200 bg-white p-5"
          >
            <div class="flex items-start justify-between gap-4">
              <div class="min-w-0">
                <p class="truncate text-lg font-semibold text-zinc-950">{agent.name}</p>
                <p class="mt-1 text-sm text-zinc-600">{agent.role} / {agent.status}</p>
              </div>
              <.link
                navigate={~p"/control/agents/#{agent.id}?workspace_id=#{@workspace_id}"}
                class="rounded-md border border-zinc-200 px-3 py-2 text-xs font-semibold text-zinc-700 transition hover:border-zinc-400"
              >
                Open
              </.link>
            </div>

            <p class="mt-3 line-clamp-2 text-sm text-zinc-600">
              {agent.description || "No description."}
            </p>

            <div class="mt-4 grid gap-3 text-sm text-zinc-600 md:grid-cols-2">
              <div>
                <p class="text-xs font-semibold uppercase tracking-[0.12em] text-zinc-500">Model</p>
                <p class="mt-1">{model_value(agent, "provider")} / {model_value(agent, "model")}</p>
              </div>
              <div>
                <p class="text-xs font-semibold uppercase tracking-[0.12em] text-zinc-500">
                  Autonomy
                </p>
                <p class="mt-1">{max_autonomy(agent)} / {approval_mode(agent)}</p>
              </div>
              <div>
                <p class="text-xs font-semibold uppercase tracking-[0.12em] text-zinc-500">Tools</p>
                <p class="mt-1">{length(capability(agent, "tools"))} tools</p>
              </div>
              <div>
                <p class="text-xs font-semibold uppercase tracking-[0.12em] text-zinc-500">Skills</p>
                <p class="mt-1">
                  {length(capability(agent, "skills"))} declared / {length(
                    Map.get(@skills_by_agent, agent.id, [])
                  )} durable
                </p>
              </div>
            </div>

            <div class="mt-4 border-t border-zinc-100 pt-4 text-xs text-zinc-500">
              <p>memory {join_or_none(agent.memory_scopes || [])}</p>
              <p class="mt-1">knowledge {join_or_none(agent.knowledge_scopes || [])}</p>
              <p class="mt-1">
                policies {length(Map.get(@policies_by_agent, agent.id, []))} / runs {length(
                  Map.get(@runs_by_agent, agent.id, [])
                )}
              </p>
              <p
                :for={{status, count} <- status_counts(Map.get(@runs_by_agent, agent.id, []))}
                class="mt-1"
              >
                {status} {count}
              </p>
            </div>
          </article>

          <div
            :if={@agents == []}
            class="rounded-lg border border-zinc-200 bg-white p-8 text-sm text-zinc-500"
          >
            No agents yet.
          </div>
        </div>
      <% else %>
        <div class="rounded-lg border border-zinc-200 bg-white p-8 text-sm text-zinc-500">
          No workspaces yet.
        </div>
      <% end %>
    </section>
    """
  end
end
