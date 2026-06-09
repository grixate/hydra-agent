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
    <div id="control-shell-frame">
      <aside
        id="control-shell-sidebar"
        class="hx-material fixed inset-y-0 left-0 z-30 hidden w-[16.5rem] rounded-none border-y-0 border-l-0 px-3 py-4 lg:flex lg:flex-col"
      >
        <div class="flex items-center gap-3 px-2 py-1">
          <div class="grid size-10 place-items-center rounded-[var(--radius-3)] bg-[var(--accent-soft)] text-sm font-semibold text-[var(--accent)]">
            H
          </div>
          <div>
            <p class="text-sm font-semibold text-zinc-950">Hydra</p>
            <p class="text-xs text-zinc-500">Self-hosted runtime</p>
          </div>
        </div>

        <div :if={@workspace_switcher} class="mt-8">
          <p class="px-2 text-[0.68rem] font-semibold uppercase tracking-[0.16em] text-zinc-500">
            Workspace
          </p>
          <nav class="mt-2 space-y-1">
            <.workspace_switcher
              active={@active}
              query={@query}
              workspace_id={@workspace_id}
              workspaces={@workspaces}
            />
          </nav>
        </div>

        <div :if={@workspace_id} class="mt-7 min-h-0 flex-1 overflow-y-auto pr-1 hydra-chat-scroll">
          <p class="px-2 text-[0.68rem] font-semibold uppercase tracking-[0.16em] text-zinc-500">
            Control
          </p>
          <.nav active={@active} workspace_id={@workspace_id} />
        </div>

        <div class="mt-auto space-y-3">
          <button
            type="button"
            data-hx-command-open
            class="hx-button hx-button-secondary w-full justify-between"
          >
            <span>Command</span>
            <span class="text-xs text-zinc-500">⌘K</span>
          </button>
          <div class="grid gap-2">
            <button type="button" data-hx-density-toggle class="hx-button hx-button-ghost">
              Compact
            </button>
          </div>
          <div class="rounded-[var(--radius-4)] bg-[var(--bg-card-subtle)] p-3 text-xs leading-5 text-zinc-600">
            <p class="font-semibold text-zinc-950">Default front door</p>
            <p class="mt-1">Telegram group chat, mirrored here with policies and memory visible.</p>
          </div>
        </div>
      </aside>

      <div
        id="control-shell-mobile-nav"
        class="hx-material mb-5 rounded-[var(--radius-5)] p-3 lg:hidden"
      >
        <div class="flex items-center justify-between gap-3">
          <div>
            <p class="text-sm font-semibold text-zinc-950">Hydra</p>
            <p class="text-xs text-zinc-500">Self-hosted runtime</p>
          </div>
          <button
            type="button"
            data-hx-command-open
            class="hx-button hx-button-secondary"
          >
            Command
          </button>
        </div>
        <div :if={@workspace_switcher} class="mt-3 flex gap-2 overflow-x-auto pb-1">
          <.workspace_switcher
            active={@active}
            compact
            query={@query}
            workspace_id={@workspace_id}
            workspaces={@workspaces}
          />
        </div>
        <.nav
          :if={@workspace_id}
          active={@active}
          compact
          id="control-shell-mobile-section-nav"
          workspace_id={@workspace_id}
        />
      </div>

      <div
        id="control-shell-header"
        class="flex flex-col gap-4 border-b border-stone-200 pb-6 lg:flex-row lg:items-end lg:justify-between"
      >
        <div class="min-w-0 space-y-2">
          <p class="text-xs font-semibold uppercase tracking-[0.12em] text-[var(--accent)]">
            {@eyebrow}
          </p>
          <h1 class="text-3xl font-semibold tracking-normal text-zinc-950">{@title}</h1>
          <p class="max-w-3xl text-sm leading-6 text-zinc-600">{@description}</p>
        </div>

        <div :if={@actions != []} class="flex flex-wrap items-center gap-2">
          {render_slot(@actions)}
        </div>
      </div>

      <div id="hx-command-palette" class="hx-command-palette" hidden>
        <div class="hx-material hx-command-panel p-3">
          <div class="flex items-center gap-3 border-b border-[var(--border-subtle)] p-3">
            <input
              id="hx-command-input"
              class="min-h-14 flex-1 border-0 bg-transparent text-base outline-none"
              placeholder="Search Hydra or jump to a control surface..."
              type="search"
            />
            <button
              type="button"
              data-hx-command-close
              aria-label="Close command palette"
              class="hx-button hx-button-ghost"
            >
              Esc
            </button>
          </div>
          <div class="grid gap-1 p-2">
            <.link
              :for={{key, label, caption} <- command_items()}
              navigate={command_path(key, @workspace_id || first_workspace_id(@workspaces))}
              class="hx-command-row"
            >
              <span>
                <span class="block text-sm font-medium">{label}</span>
                <span class="block text-xs text-zinc-500">{caption}</span>
              </span>
            </.link>
          </div>
        </div>
      </div>
    </div>
    """
  end

  attr :active, :atom, required: true
  attr :compact, :boolean, default: false
  attr :query, :map, required: true
  attr :workspace_id, :any, required: true
  attr :workspaces, :list, required: true

  defp workspace_switcher(assigns) do
    ~H"""
    <.link
      :for={workspace <- @workspaces}
      patch={workspace_path(@active, workspace.id, @query)}
      class={[
        @compact && "shrink-0 rounded-full border px-3 py-2 text-sm font-medium transition",
        !@compact && "block rounded-[var(--radius-3)] px-3 py-2 text-sm font-medium transition",
        workspace.id == @workspace_id && "border-transparent bg-[var(--accent)] text-white shadow-sm",
        workspace.id != @workspace_id &&
          "border-transparent bg-transparent text-zinc-700 hover:bg-[var(--bg-hover)]"
      ]}
    >
      {workspace.name}
    </.link>
    """
  end

  attr :active, :atom, required: true
  attr :compact, :boolean, default: false
  attr :id, :string, default: "control-shell-nav"
  attr :workspace_id, :any, required: true

  defp nav(assigns) do
    ~H"""
    <nav
      :if={@workspace_id}
      id={@id}
      class={[
        @compact && "hydra-chat-scroll mt-3 flex gap-2 overflow-x-auto pb-1",
        !@compact && "mt-2 space-y-1"
      ]}
    >
      <.link
        :for={{key, label, caption} <- nav_items()}
        navigate={nav_path(key, @workspace_id)}
        class={[
          @compact && "shrink-0 rounded-full px-3 py-2 text-sm",
          !@compact && "block rounded-[var(--radius-3)] px-3 py-2",
          "transition",
          key == @active && "bg-[var(--bg-active)] text-[var(--accent)] shadow-sm",
          key != @active && "text-zinc-700 hover:bg-[var(--bg-hover)]"
        ]}
      >
        <span class="block text-sm font-medium">{label}</span>
        <span
          :if={!@compact}
          class={[
            "mt-0.5 block text-xs",
            key == @active && "text-zinc-500",
            key != @active && "text-zinc-500"
          ]}
        >
          {caption}
        </span>
      </.link>
    </nav>
    """
  end

  defp nav_items do
    [
      {:studio, "Team Chat", "Rooms and agent handoff"},
      {:mission, "Missions", "Goals and supervised work"},
      {:agents, "Agents", "People on the team"},
      {:memory, "Memory", "Second brain curation"},
      {:graph, "Graph", "Knowledge relationships"},
      {:skills, "Skills", "Evolution and evals"},
      {:loops, "Loops", "Governed operating programs"},
      {:automations, "Automations", "Briefings and watches"},
      {:runtime, "Runtime", "Runs, approvals, recovery"},
      {:simulations, "Simulations", "Budget-capped rehearsals"},
      {:settings, "Settings", "Budgets and providers"},
      {:tools, "Tools", "MCP, connectors, imports"}
    ]
  end

  defp command_items do
    [
      {:mission, "Start mission", "Composer and active mission feed"},
      {:studio, "Open team chat", "Shared Telegram-style agent room"},
      {:runtime, "Open runtime health", "Runs, approvals, and recovery"},
      {:skills, "Search skills", "Skill library and evolution queue"},
      {:loops, "Open loops", "Governed recurring missions"},
      {:memory, "Search memory", "Second brain curation"},
      {:graph, "Search graph", "Knowledge relationships"},
      {:agents, "Create agent", "Roster and specialist setup"},
      {:automations, "Open automations", "Briefings, watches, reminders"},
      {:tools, "Open connectors", "MCP, browser, and skill imports"}
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

  defp workspace_path(:loops, workspace_id, query) do
    status = query_value(query, :status, "all")

    ~p"/control/loops?workspace_id=#{workspace_id}&status=#{status}"
  end

  defp workspace_path(active, workspace_id, _query), do: nav_path(active, workspace_id)

  defp nav_path(:mission, workspace_id), do: ~p"/control/missions?workspace_id=#{workspace_id}"

  defp nav_path(:automations, workspace_id),
    do: ~p"/control/automations?workspace_id=#{workspace_id}"

  defp nav_path(:agents, workspace_id), do: ~p"/control/agents?workspace_id=#{workspace_id}"

  defp nav_path(:studio, workspace_id),
    do: ~p"/control/agents/studio?workspace_id=#{workspace_id}"

  defp nav_path(:memory, workspace_id), do: ~p"/control/memory?workspace_id=#{workspace_id}"
  defp nav_path(:graph, workspace_id), do: ~p"/control/graph?workspace_id=#{workspace_id}"
  defp nav_path(:skills, workspace_id), do: ~p"/control/skills?workspace_id=#{workspace_id}"
  defp nav_path(:loops, workspace_id), do: ~p"/control/loops?workspace_id=#{workspace_id}"
  defp nav_path(:runtime, workspace_id), do: ~p"/control/runtime?workspace_id=#{workspace_id}"

  defp nav_path(:simulations, workspace_id),
    do: ~p"/control/simulations?workspace_id=#{workspace_id}"

  defp nav_path(:settings, workspace_id), do: ~p"/control/settings?workspace_id=#{workspace_id}"
  defp nav_path(:tools, workspace_id), do: ~p"/control/tools?workspace_id=#{workspace_id}"
  defp nav_path(_active, workspace_id), do: nav_path(:mission, workspace_id)

  defp command_path(_key, nil), do: ~p"/control"
  defp command_path(key, workspace_id), do: nav_path(key, workspace_id)

  defp query_value(query, key, default) do
    Map.get(query, key) || Map.get(query, to_string(key)) || default
  end

  defp first_workspace_id([workspace | _workspaces]), do: workspace.id
  defp first_workspace_id([]), do: nil
end
