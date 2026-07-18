defmodule HydraAgentWeb.ControlShell do
  use HydraAgentWeb, :html

  attr :active, :atom, default: :mission
  attr :description, :string, required: true
  attr :eyebrow, :string, required: true
  attr :query, :map, default: %{}
  attr :title, :string, required: true
  attr :workspace_id, :any, default: nil
  attr :workspaces, :list, default: []
  attr :workspace_switcher, :boolean, default: true
  slot :actions

  def header(assigns) do
    ~H"""
    <div
      id="control-shell-header"
      class="control-shell-header"
    >
      <div class="control-shell-heading">
        <div class="min-w-0 space-y-2">
          <p class="control-eyebrow">{@eyebrow}</p>
          <h1>{@title}</h1>
          <p class="control-description">{@description}</p>
        </div>
        <div class="control-actions">{render_slot(@actions)}</div>
      </div>

      <div class="control-context-bar">
        <.workspace_switcher
          :if={@workspace_switcher}
          active={@active}
          query={@query}
          workspace_id={@workspace_id}
          workspaces={@workspaces}
        />
        <.nav active={@active} workspace_id={@workspace_id} />
      </div>
    </div>
    """
  end

  attr :active, :atom, required: true
  attr :query, :map, required: true
  attr :workspace_id, :any, required: true
  attr :workspaces, :list, required: true

  defp workspace_switcher(assigns) do
    ~H"""
    <div :if={@workspaces != []} class="workspace-switcher" aria-label="Workspace">
      <span>Workspace</span>
      <.link
        :for={workspace <- @workspaces}
        patch={workspace_path(@active, workspace.id, @query)}
        aria-current={if workspace.id == @workspace_id, do: "true"}
        class={["workspace-option", workspace.id == @workspace_id && "is-active"]}
      >
        {workspace.name}
      </.link>
    </div>
    """
  end

  attr :active, :atom, required: true
  attr :workspace_id, :any, required: true

  defp nav(assigns) do
    ~H"""
    <nav :if={@workspace_id} id="control-shell-nav" class="control-section-nav" aria-label="Workspace">
      <.link
        :for={{key, label} <- nav_items()}
        navigate={nav_path(key, @workspace_id)}
        aria-current={if key == @active, do: "page"}
        class={["control-section-link", key == @active && "is-active"]}
      >
        {label}
      </.link>
    </nav>
    """
  end

  defp nav_items do
    [
      overview: "Overview",
      mission: "Missions",
      agents: "Agents",
      memory: "Memory",
      graph: "Graph",
      skills: "Skills",
      automations: "Automations",
      runtime: "Runtime",
      settings: "Settings",
      tools: "Tools"
    ]
  end

  defp workspace_path(:memory, workspace_id, query) do
    q = query_value(query, :q, "")
    status = query_value(query, :status, "active")

    ~p"/control/memory?workspace_id=#{workspace_id}&q=#{q}&status=#{status}"
  end

  defp workspace_path(:graph, workspace_id, query) do
    node_type = query_value(query, :node_type, "")
    node_status = query_value(query, :node_status, "all")
    relationship_type = query_value(query, :relationship_type, "")
    provenance = query_value(query, :provenance, "")

    ~p"/control/graph?workspace_id=#{workspace_id}&node_type=#{node_type}&node_status=#{node_status}&relationship_type=#{relationship_type}&provenance=#{provenance}"
  end

  defp workspace_path(:skills, workspace_id, query) do
    status = query_value(query, :status, "all")

    ~p"/control/skills?workspace_id=#{workspace_id}&status=#{status}"
  end

  defp workspace_path(:automations, workspace_id, query) do
    status = query_value(query, :status, "all")

    ~p"/control/automations?workspace_id=#{workspace_id}&status=#{status}"
  end

  defp workspace_path(active, workspace_id, _query), do: nav_path(active, workspace_id)

  defp nav_path(:overview, workspace_id), do: ~p"/control?workspace_id=#{workspace_id}"
  defp nav_path(:mission, workspace_id), do: ~p"/control/missions?workspace_id=#{workspace_id}"

  defp nav_path(:automations, workspace_id),
    do: ~p"/control/automations?workspace_id=#{workspace_id}"

  defp nav_path(:agents, workspace_id), do: ~p"/control/agents?workspace_id=#{workspace_id}"
  defp nav_path(:memory, workspace_id), do: ~p"/control/memory?workspace_id=#{workspace_id}"
  defp nav_path(:graph, workspace_id), do: ~p"/control/graph?workspace_id=#{workspace_id}"
  defp nav_path(:skills, workspace_id), do: ~p"/control/skills?workspace_id=#{workspace_id}"
  defp nav_path(:runtime, workspace_id), do: ~p"/control/runtime?workspace_id=#{workspace_id}"
  defp nav_path(:settings, workspace_id), do: ~p"/control/settings?workspace_id=#{workspace_id}"
  defp nav_path(:tools, workspace_id), do: ~p"/control/tools?workspace_id=#{workspace_id}"
  defp nav_path(_active, workspace_id), do: nav_path(:mission, workspace_id)

  defp query_value(query, key, default) do
    Map.get(query, key) || Map.get(query, to_string(key)) || default
  end
end
