defmodule HydraAgentWeb.ControlComponents do
  use HydraAgentWeb, :html

  def header(assigns) do
    ~H"""
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
        <.link
          :if={@workspace_id}
          navigate={~p"/control/agents?workspace_id=#{@workspace_id}"}
          class="rounded-md border border-zinc-200 bg-white px-3 py-2 text-sm font-medium text-zinc-700 transition hover:border-zinc-400"
        >
          Agents
        </.link>
        <.link
          :if={@workspace_id}
          navigate={~p"/control/memory?workspace_id=#{@workspace_id}"}
          class="rounded-md border border-zinc-200 bg-white px-3 py-2 text-sm font-medium text-zinc-700 transition hover:border-zinc-400"
        >
          Memory
        </.link>
        <.link
          :if={@workspace_id}
          navigate={~p"/control/graph?workspace_id=#{@workspace_id}"}
          class="rounded-md border border-zinc-200 bg-white px-3 py-2 text-sm font-medium text-zinc-700 transition hover:border-zinc-400"
        >
          Graph
        </.link>
        <.link
          :if={@workspace_id}
          navigate={~p"/control/runtime?workspace_id=#{@workspace_id}"}
          class="rounded-md border border-zinc-200 bg-white px-3 py-2 text-sm font-medium text-zinc-700 transition hover:border-zinc-400"
        >
          Runtime
        </.link>
        <.link
          :if={@workspace_id}
          navigate={~p"/control/tools?workspace_id=#{@workspace_id}"}
          class="rounded-md border border-zinc-200 bg-white px-3 py-2 text-sm font-medium text-zinc-700 transition hover:border-zinc-400"
        >
          Tools
        </.link>
      </div>
    </div>
    """
  end

  def metrics(assigns) do
    ~H"""
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
    """
  end

  def runs_panel(assigns) do
    ~H"""
    <section class="space-y-3">
      <div class="flex items-center justify-between">
        <h2 class="text-lg font-semibold text-zinc-950">Runs</h2>
        <p class="text-sm text-zinc-500">
          latest: {(@runs |> latest_run() || %{inserted_at: nil}).inserted_at |> timestamp()}
        </p>
      </div>
      <div id="control-runs" class="space-y-2">
        <div
          :for={run <- Enum.take(@runs, 8)}
          id={"control-run-#{run.id}"}
          class="rounded-lg border border-zinc-200 bg-white p-4"
        >
          <% worker_status = Map.get(@worker_statuses, run.id, %{active: false}) %>
          <div class="flex flex-col gap-3 lg:flex-row lg:items-start lg:justify-between">
            <div class="min-w-0">
              <div class="flex flex-wrap items-center gap-2">
                <span class="text-xs font-medium uppercase tracking-[0.1em] text-zinc-500">
                  Run #{run.id}
                </span>
                <span class="hx-status-pill">{run.status}</span>
                <span class="hx-status-pill">{run.autonomy_level}</span>
              </div>
              <p class="mt-2 truncate text-sm font-semibold text-zinc-950">{run.title}</p>
              <p class="mt-1 line-clamp-2 text-sm text-zinc-600">{run.goal}</p>
              <.link
                navigate={~p"/control/runs/#{run.id}"}
                class="mt-2 inline-flex text-xs font-semibold text-zinc-950 underline decoration-zinc-300 underline-offset-2 hover:decoration-zinc-950"
              >
                Open timeline
              </.link>
            </div>
            <div class="min-w-[9rem] rounded-[var(--radius-3)] bg-[var(--bg-card-subtle)] px-3 py-2 text-sm text-zinc-700">
              <p class={[
                "font-medium",
                worker_status.active && "text-emerald-700",
                !worker_status.active && "text-zinc-500"
              ]}>
                {if worker_status.active, do: "Worker active", else: "Worker idle"}
              </p>
              <p class="mt-1 truncate text-xs text-zinc-500">
                {worker_status.current_step_title || "no active step"}
              </p>
            </div>
          </div>
          <div class="mt-4 flex flex-wrap gap-2">
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
        <div
          :if={@runs == []}
          class="rounded-lg border border-zinc-200 bg-white p-4 text-sm text-zinc-500"
        >
          No runs yet.
        </div>
      </div>
    </section>
    """
  end

  def approvals_panel(assigns) do
    ~H"""
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
    """
  end

  def operations_grid(assigns) do
    ~H"""
    <div class="grid gap-6 xl:grid-cols-4">
      <.safety_panel safety_events={@safety_events} />
      <.budgets_panel budget_statuses={@budget_statuses} />
      <.providers_panel providers={@providers} />
      <.tools_panel
        tool_bundles={@tool_bundles}
        tool_policies={@tool_policies}
        mcp_servers={@mcp_servers}
      />
    </div>
    """
  end

  def knowledge_graph(assigns) do
    ~H"""
    <section class="space-y-3">
      <h2 class="text-lg font-semibold text-zinc-950">Knowledge Graph</h2>
      <div class="grid gap-6 xl:grid-cols-[0.8fr_1.2fr]">
        <.memory_review memory_proposals={@memory_proposals} />
        <div class="space-y-4">
          <.graph_nodes nodes={@nodes} />
          <.graph_provenance relationships={@relationships} />
        </div>
      </div>
    </section>
    """
  end

  def empty_state(assigns) do
    ~H"""
    <div class="rounded-lg border border-zinc-200 bg-white p-8 text-sm text-zinc-500">
      No workspaces yet.
    </div>
    """
  end

  defp safety_panel(assigns) do
    ~H"""
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
    """
  end

  defp budgets_panel(assigns) do
    ~H"""
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
    """
  end

  defp providers_panel(assigns) do
    ~H"""
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
    """
  end

  defp tools_panel(assigns) do
    ~H"""
    <section class="space-y-3">
      <h2 class="text-lg font-semibold text-zinc-950">Tools</h2>
      <div id="control-tool-bundles" class="space-y-2">
        <div
          :for={bundle <- @tool_bundles}
          id={"control-tool-bundle-#{bundle.name}"}
          class="rounded-lg border border-zinc-200 bg-white p-4"
        >
          <div class="flex items-start justify-between gap-3">
            <div class="min-w-0">
              <p class="truncate text-sm font-semibold text-zinc-950">{bundle.name}</p>
              <p class="mt-1 line-clamp-2 text-sm text-zinc-600">{bundle.description}</p>
            </div>
            <span class={[
              "text-xs font-medium uppercase",
              bundle.requires_approval && "text-amber-700",
              !bundle.requires_approval && "text-emerald-700"
            ]}>
              {if bundle.requires_approval, do: "approval", else: "safe"}
            </span>
          </div>
          <p class="mt-2 text-xs text-zinc-500">
            {Enum.join(bundle.side_effect_classes, ", ")}
          </p>
        </div>
      </div>

      <.tool_policies tool_policies={@tool_policies} />
      <.mcp_servers mcp_servers={@mcp_servers} />
    </section>
    """
  end

  defp tool_policies(assigns) do
    ~H"""
    <div id="control-tool-policies" class="space-y-2">
      <h3 class="text-sm font-semibold text-zinc-950">Policy Grants</h3>
      <div
        :for={policy <- Enum.take(@tool_policies, 4)}
        id={"control-tool-policy-#{policy.id}"}
        class="rounded-lg border border-zinc-200 bg-white p-4"
      >
        <p class="text-sm font-semibold text-zinc-950">
          {policy.scope} policy #{policy.id}
        </p>
        <p class="mt-1 text-xs text-zinc-500">
          bundles {join_or_none(policy_bundles(policy))}
        </p>
        <p class="mt-1 text-xs text-zinc-500">
          tools {length(policy.allowed_tools || [])} / classes {join_or_none(
            policy.side_effect_classes || []
          )}
        </p>
        <p class="mt-1 text-xs text-zinc-500">
          shell env {join_or_none(policy.shell_env_allowlist || [])}
        </p>
      </div>
      <div
        :if={@tool_policies == []}
        class="rounded-lg border border-zinc-200 bg-white p-4 text-sm text-zinc-500"
      >
        No tool policies configured.
      </div>
    </div>
    """
  end

  defp mcp_servers(assigns) do
    ~H"""
    <div id="control-mcp-servers" class="space-y-2">
      <h3 class="text-sm font-semibold text-zinc-950">MCP Servers</h3>
      <div
        :for={server <- Enum.take(@mcp_servers, 4)}
        id={"control-mcp-server-#{server.id}"}
        class="rounded-lg border border-zinc-200 bg-white p-4"
      >
        <div class="flex items-start justify-between gap-3">
          <div class="min-w-0">
            <p class="truncate text-sm font-semibold text-zinc-950">{server.name}</p>
            <p class="mt-1 text-xs text-zinc-500">
              {server.transport} / {server.trust_level} / {server.health_status}
            </p>
          </div>
          <span class={[
            "text-xs font-medium uppercase",
            server.approval_sensitive && "text-amber-700",
            !server.approval_sensitive && "text-emerald-700"
          ]}>
            {if server.approval_sensitive, do: "approval", else: "non-sensitive"}
          </span>
        </div>
        <p class="mt-2 text-xs text-zinc-500">
          tools {join_or_none(server.include_tools || [])} / env {join_or_none(server.env_refs || [])}
        </p>
      </div>
      <div
        :if={@mcp_servers == []}
        class="rounded-lg border border-zinc-200 bg-white p-4 text-sm text-zinc-500"
      >
        No MCP servers configured.
      </div>
    </div>
    """
  end

  defp memory_review(assigns) do
    ~H"""
    <div id="control-memory-proposals" class="space-y-2">
      <div class="flex items-center justify-between gap-3">
        <h3 class="text-sm font-semibold text-zinc-950">Memory Review</h3>
        <span class="text-xs font-medium text-zinc-500">
          {length(@memory_proposals)} pending
        </span>
      </div>
      <div
        :for={proposal <- @memory_proposals}
        id={"control-memory-proposal-#{proposal.id}"}
        class="rounded-lg border border-zinc-200 bg-white p-4"
      >
        <p class="text-sm font-semibold text-zinc-950">{proposal.title}</p>
        <p class="mt-1 line-clamp-2 text-sm text-zinc-600">{proposal.body}</p>
        <p class="mt-2 text-xs text-zinc-500">
          confidence {proposal.confidence} / importance {proposal.importance}
        </p>
        <form
          id={"control-review-memory-form-#{proposal.id}"}
          phx-submit="review-memory"
          class="mt-3 space-y-2"
        >
          <input type="hidden" name="proposal_id" value={proposal.id} />
          <input
            id={"control-memory-reason-#{proposal.id}"}
            name="reason"
            type="text"
            placeholder="Review reason"
            class="w-full rounded-md border border-zinc-200 px-2 py-1 text-xs text-zinc-700 placeholder:text-zinc-400 focus:border-zinc-400 focus:outline-none"
          />
          <div class="flex gap-2">
            <button
              id={"control-promote-memory-#{proposal.id}"}
              type="submit"
              name="decision"
              value="promote"
              class="rounded-md border border-emerald-200 px-2 py-1 text-xs font-medium text-emerald-700 transition hover:border-emerald-400"
            >
              Promote
            </button>
            <button
              id={"control-reject-memory-#{proposal.id}"}
              type="submit"
              name="decision"
              value="reject"
              class="rounded-md border border-red-200 px-2 py-1 text-xs font-medium text-red-700 transition hover:border-red-400"
            >
              Reject
            </button>
          </div>
        </form>
      </div>
      <div
        :if={@memory_proposals == []}
        class="rounded-lg border border-zinc-200 bg-white p-4 text-sm text-zinc-500"
      >
        No pending memory proposals.
      </div>
    </div>
    """
  end

  defp graph_nodes(assigns) do
    ~H"""
    <div id="control-graph" class="grid gap-3 md:grid-cols-2">
      <div
        :for={node <- @nodes}
        id={"control-node-#{node.id}"}
        class="rounded-lg border border-zinc-200 bg-white p-4"
      >
        <p class="text-xs font-semibold uppercase tracking-[0.12em] text-zinc-500">
          {node.type_key}
        </p>
        <p class="mt-2 truncate text-sm font-semibold text-zinc-950">{node.title}</p>
        <p class="mt-1 text-xs text-zinc-500">
          confidence {node.confidence} / provenance {provenance_kind(node)}
        </p>
      </div>
      <div
        :if={@nodes == []}
        class="rounded-lg border border-zinc-200 bg-white p-4 text-sm text-zinc-500"
      >
        No graph nodes.
      </div>
    </div>
    """
  end

  defp graph_provenance(assigns) do
    ~H"""
    <div id="control-graph-provenance" class="space-y-2">
      <h3 class="text-sm font-semibold text-zinc-950">Graph Provenance</h3>
      <div
        :for={relationship <- @relationships}
        id={"control-relationship-#{relationship.id}"}
        class="rounded-lg border border-zinc-200 bg-white p-4"
      >
        <p class="text-sm font-semibold text-zinc-950">
          {relationship_label(relationship)}
        </p>
        <p class="mt-1 text-xs text-zinc-500">
          confidence {relationship.confidence} / provenance {provenance_kind(relationship)}
        </p>
      </div>
      <div
        :if={@relationships == []}
        class="rounded-lg border border-zinc-200 bg-white p-4 text-sm text-zinc-500"
      >
        No graph relationships.
      </div>
    </div>
    """
  end

  defp latest_run(runs), do: List.first(runs)

  defp percent(nil), do: "n/a"
  defp percent(value), do: "#{Float.round(value * 100, 1)}%"

  defp timestamp(nil), do: "n/a"

  defp timestamp(datetime) do
    Calendar.strftime(datetime, "%m-%d %H:%M")
  end

  defp provenance_kind(%{provenance: %{"kind" => kind}}) when is_binary(kind), do: kind
  defp provenance_kind(_record), do: "manual"

  defp relationship_label(relationship) do
    from_title = relationship.from_node && relationship.from_node.title
    to_title = relationship.to_node && relationship.to_node.title

    "#{from_title || "unknown"} #{relationship.type_key} #{to_title || "unknown"}"
  end

  defp policy_bundles(policy), do: get_in(policy.metadata || %{}, ["tool_bundles"]) || []

  defp join_or_none([]), do: "none"
  defp join_or_none(values), do: Enum.join(values, ", ")
end
