defmodule HydraAgentWeb.AgentDetailLive do
  use HydraAgentWeb, :live_view

  alias HydraAgent.{Runtime, Skills}
  alias HydraAgentWeb.ControlShell

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Agent Detail")
     |> assign(:workspace_id, nil)
     |> load_workspaces()}
  end

  @impl true
  def handle_params(%{"id" => id} = params, _uri, socket) do
    agent = Runtime.get_agent!(id)

    workspace_id =
      selected_workspace_id(
        socket.assigns.workspaces,
        params["workspace_id"] || agent.workspace_id
      )

    workspace_id =
      if workspace_id == agent.workspace_id, do: workspace_id, else: agent.workspace_id

    socket =
      socket
      |> assign(:workspace_id, workspace_id)
      |> assign(:agent, agent)
      |> load_agent_state()

    {:noreply, socket}
  end

  defp load_workspaces(socket) do
    assign(socket, :workspaces, Runtime.list_workspaces())
  end

  defp load_agent_state(%{assigns: %{agent: agent, workspace_id: workspace_id}} = socket) do
    skills =
      workspace_id
      |> Skills.list_skills()
      |> Enum.filter(&(&1.owner_agent_id == agent.id))

    policies =
      workspace_id
      |> Runtime.list_tool_policies()
      |> Enum.filter(&(&1.agent_id in [nil, agent.id]))

    socket
    |> assign(:runs, Runtime.list_agent_runs(workspace_id, agent.id, limit: 8))
    |> assign(
      :assigned_steps,
      Runtime.list_agent_assigned_steps(workspace_id, agent.id, limit: 8)
    )
    |> assign(:skills, skills)
    |> assign(:policies, policies)
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

  defp capability(agent, key), do: get_in(agent.capability_profile || %{}, [key]) || []

  defp approval_mode(agent),
    do:
      get_in(agent.capability_profile || %{}, ["approval_policy", "mode"]) ||
        "required_for_sensitive"

  defp max_autonomy(agent),
    do: get_in(agent.capability_profile || %{}, ["max_autonomy_level"]) || "recommend"

  defp model_value(agent, key), do: get_in(agent.model_route || %{}, [key]) || "default"

  defp join_or_none([]), do: "none"
  defp join_or_none(values), do: Enum.join(values, ", ")

  defp timestamp(nil), do: "n/a"
  defp timestamp(datetime), do: Calendar.strftime(datetime, "%m-%d %H:%M")

  @impl true
  def render(assigns) do
    ~H"""
    <section id="agent-detail" class="space-y-8">
      <ControlShell.header
        active={:agents}
        description={@agent.description || "No description."}
        eyebrow="Agent detail"
        title={@agent.name}
        workspaces={@workspaces}
        workspace_id={@workspace_id}
        workspace_switcher={false}
      >
        <:actions>
          <.link
            navigate={~p"/control/agents?workspace_id=#{@workspace_id}"}
            class="rounded-md border border-zinc-200 bg-white px-3 py-2 text-sm font-medium text-zinc-700 transition hover:border-zinc-400"
          >
            Agent Directory
          </.link>
        </:actions>
      </ControlShell.header>

      <div class="grid gap-4 md:grid-cols-2 xl:grid-cols-4">
        <div class="rounded-lg border border-zinc-200 bg-white p-4">
          <p class="text-xs font-semibold uppercase tracking-[0.14em] text-zinc-500">Role</p>
          <p class="mt-3 text-2xl font-semibold text-zinc-950">{@agent.role}</p>
          <p class="mt-1 text-sm text-zinc-600">{@agent.status}</p>
        </div>
        <div class="rounded-lg border border-zinc-200 bg-white p-4">
          <p class="text-xs font-semibold uppercase tracking-[0.14em] text-zinc-500">Model</p>
          <p class="mt-3 text-2xl font-semibold text-zinc-950">{model_value(@agent, "model")}</p>
          <p class="mt-1 text-sm text-zinc-600">{model_value(@agent, "provider")}</p>
        </div>
        <div class="rounded-lg border border-zinc-200 bg-white p-4">
          <p class="text-xs font-semibold uppercase tracking-[0.14em] text-zinc-500">Autonomy</p>
          <p class="mt-3 text-2xl font-semibold text-zinc-950">{max_autonomy(@agent)}</p>
          <p class="mt-1 text-sm text-zinc-600">{approval_mode(@agent)}</p>
        </div>
        <div class="rounded-lg border border-zinc-200 bg-white p-4">
          <p class="text-xs font-semibold uppercase tracking-[0.14em] text-zinc-500">Load</p>
          <p class="mt-3 text-2xl font-semibold text-zinc-950">{length(@runs)}</p>
          <p class="mt-1 text-sm text-zinc-600">{length(@assigned_steps)} recent assigned steps</p>
        </div>
      </div>

      <div class="grid gap-6 xl:grid-cols-[1.2fr_0.8fr]">
        <section class="space-y-3">
          <h2 class="text-lg font-semibold text-zinc-950">Capabilities</h2>
          <div id="agent-detail-capabilities" class="grid gap-3 md:grid-cols-2">
            <div class="rounded-lg border border-zinc-200 bg-white p-4">
              <p class="text-sm font-semibold text-zinc-950">Tools</p>
              <p class="mt-2 text-sm text-zinc-600">{join_or_none(capability(@agent, "tools"))}</p>
              <p class="mt-2 text-xs text-zinc-500">
                bundles {join_or_none(capability(@agent, "tool_bundles"))}
              </p>
            </div>
            <div class="rounded-lg border border-zinc-200 bg-white p-4">
              <p class="text-sm font-semibold text-zinc-950">Scopes</p>
              <p class="mt-2 text-sm text-zinc-600">
                memory {join_or_none(@agent.memory_scopes || [])}
              </p>
              <p class="mt-1 text-sm text-zinc-600">
                knowledge {join_or_none(@agent.knowledge_scopes || [])}
              </p>
            </div>
          </div>
        </section>

        <section class="space-y-3">
          <h2 class="text-lg font-semibold text-zinc-950">Skills</h2>
          <div id="agent-detail-skills" class="space-y-2">
            <div
              :for={skill <- @skills}
              id={"agent-detail-skill-#{skill.id}"}
              class="rounded-lg border border-zinc-200 bg-white p-4"
            >
              <p class="text-sm font-semibold text-zinc-950">{skill.name}</p>
              <p class="mt-1 text-xs font-medium uppercase text-zinc-500">{skill.status}</p>
              <p class="mt-2 text-sm text-zinc-600">{skill.description}</p>
            </div>
            <div
              :if={@skills == []}
              class="rounded-lg border border-zinc-200 bg-white p-4 text-sm text-zinc-500"
            >
              No durable skills owned by this agent.
            </div>
          </div>
        </section>
      </div>

      <div class="grid gap-6 xl:grid-cols-2">
        <section class="space-y-3">
          <h2 class="text-lg font-semibold text-zinc-950">Recent Runs</h2>
          <div id="agent-detail-runs" class="space-y-2">
            <div
              :for={run <- @runs}
              id={"agent-detail-run-#{run.id}"}
              class="rounded-lg border border-zinc-200 bg-white p-4"
            >
              <div class="flex items-start justify-between gap-3">
                <div class="min-w-0">
                  <p class="truncate text-sm font-semibold text-zinc-950">{run.title}</p>
                  <p class="mt-1 truncate text-sm text-zinc-600">{run.goal}</p>
                </div>
                <span class="text-xs font-medium uppercase text-zinc-500">{run.status}</span>
              </div>
              <.link
                navigate={~p"/control/runs/#{run.id}"}
                class="mt-3 inline-flex text-xs font-semibold text-zinc-950 underline decoration-zinc-300 underline-offset-2 hover:decoration-zinc-950"
              >
                Open timeline
              </.link>
            </div>
            <div
              :if={@runs == []}
              class="rounded-lg border border-zinc-200 bg-white p-4 text-sm text-zinc-500"
            >
              No supervised runs.
            </div>
          </div>
        </section>

        <section class="space-y-3">
          <h2 class="text-lg font-semibold text-zinc-950">Assigned Steps</h2>
          <div id="agent-detail-assigned-steps" class="space-y-2">
            <div
              :for={step <- @assigned_steps}
              id={"agent-detail-step-#{step.id}"}
              class="rounded-lg border border-zinc-200 bg-white p-4"
            >
              <div class="flex items-start justify-between gap-3">
                <div class="min-w-0">
                  <p class="truncate text-sm font-semibold text-zinc-950">{step.title}</p>
                  <p class="mt-1 truncate text-sm text-zinc-600">{step.run.title}</p>
                </div>
                <span class="text-xs font-medium uppercase text-zinc-500">{step.status}</span>
              </div>
              <p class="mt-2 text-xs text-zinc-500">
                {step.tool_name || "no tool"} / {step.side_effect_class} / {timestamp(
                  step.inserted_at
                )}
              </p>
            </div>
            <div
              :if={@assigned_steps == []}
              class="rounded-lg border border-zinc-200 bg-white p-4 text-sm text-zinc-500"
            >
              No assigned steps.
            </div>
          </div>
        </section>
      </div>

      <section class="space-y-3">
        <h2 class="text-lg font-semibold text-zinc-950">Tool Policies</h2>
        <div id="agent-detail-policies" class="grid gap-3 md:grid-cols-2">
          <div
            :for={policy <- @policies}
            id={"agent-detail-policy-#{policy.id}"}
            class="rounded-lg border border-zinc-200 bg-white p-4"
          >
            <p class="text-sm font-semibold text-zinc-950">
              {if policy.agent_id, do: "Agent policy", else: "Workspace policy"} #{policy.id}
            </p>
            <p class="mt-2 text-sm text-zinc-600">
              tools {join_or_none(policy.allowed_tools || [])}
            </p>
            <p class="mt-1 text-xs text-zinc-500">
              classes {join_or_none(policy.side_effect_classes || [])}
            </p>
            <p class="mt-1 text-xs text-zinc-500">
              shell env {join_or_none(policy.shell_env_allowlist || [])}
            </p>
          </div>
          <div
            :if={@policies == []}
            class="rounded-lg border border-zinc-200 bg-white p-4 text-sm text-zinc-500"
          >
            No matching tool policies.
          </div>
        </div>
      </section>
    </section>
    """
  end
end
