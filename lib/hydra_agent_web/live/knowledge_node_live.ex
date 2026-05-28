defmodule HydraAgentWeb.KnowledgeNodeLive do
  use HydraAgentWeb, :live_view

  alias HydraAgent.{Knowledge, Runtime}
  alias HydraAgentWeb.ControlShell

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Knowledge Detail")
     |> assign(:workspace_id, nil)
     |> load_workspaces()}
  end

  @impl true
  def handle_params(%{"id" => id} = params, _uri, socket) do
    node = Knowledge.get_node_detail!(id)

    workspace_id =
      selected_workspace_id(socket.assigns.workspaces, params["workspace_id"]) ||
        node.workspace_id

    {:noreply,
     socket
     |> assign(:workspace_id, workspace_id)
     |> assign(:node, node)}
  end

  defp load_workspaces(socket) do
    assign(socket, :workspaces, Runtime.list_workspaces())
  end

  defp selected_workspace_id([], _param), do: nil
  defp selected_workspace_id(_workspaces, nil), do: nil

  defp selected_workspace_id(workspaces, workspace_id) do
    parsed_id = parse_id(workspace_id)

    if Enum.any?(workspaces, &(&1.id == parsed_id)), do: parsed_id
  end

  defp parse_id(id) when is_integer(id), do: id

  defp parse_id(id) when is_binary(id) do
    case Integer.parse(id) do
      {parsed, ""} -> parsed
      _other -> nil
    end
  end

  defp parse_id(_id), do: nil

  defp outgoing(node),
    do: (Ecto.assoc_loaded?(node.outgoing_relationships) && node.outgoing_relationships) || []

  defp incoming(node),
    do: (Ecto.assoc_loaded?(node.incoming_relationships) && node.incoming_relationships) || []

  @impl true
  def render(assigns) do
    ~H"""
    <section id={"knowledge-node-#{@node.id}"} class="space-y-8">
      <ControlShell.header
        active={if @node.type_key == "memory", do: :memory, else: :graph}
        description="Inspect graph context, provenance, confidence, and directly connected relationships."
        eyebrow="Knowledge detail"
        title={@node.title}
        workspaces={@workspaces}
        workspace_id={@workspace_id}
      />

      <div class="grid gap-6 xl:grid-cols-[1fr_360px]">
        <section class="rounded-lg border border-zinc-200 bg-white p-5">
          <div class="flex flex-wrap items-center gap-2 text-xs font-semibold uppercase tracking-[0.14em]">
            <span class="rounded-md bg-zinc-100 px-2 py-1 text-zinc-700">{@node.type_key}</span>
            <span class="rounded-md bg-zinc-100 px-2 py-1 text-zinc-700">{@node.status}</span>
          </div>
          <p class="mt-4 whitespace-pre-wrap text-sm leading-6 text-zinc-700">{@node.body}</p>
          <dl class="mt-6 grid gap-4 md:grid-cols-2">
            <div class="rounded-lg border border-zinc-200 p-4">
              <dt class="text-xs font-semibold uppercase tracking-[0.14em] text-zinc-500">
                Confidence
              </dt>
              <dd class="mt-2 text-2xl font-semibold text-zinc-950">{@node.confidence}</dd>
            </div>
            <div class="rounded-lg border border-zinc-200 p-4">
              <dt class="text-xs font-semibold uppercase tracking-[0.14em] text-zinc-500">
                Importance
              </dt>
              <dd class="mt-2 text-2xl font-semibold text-zinc-950">{@node.importance}</dd>
            </div>
          </dl>
        </section>

        <aside class="space-y-4">
          <section class="rounded-lg border border-zinc-200 bg-white p-4">
            <h2 class="text-base font-semibold text-zinc-950">Provenance</h2>
            <pre class="mt-3 overflow-auto rounded-md bg-zinc-950 p-3 text-xs text-white"><%= inspect(@node.provenance, pretty: true) %></pre>
          </section>
          <section class="rounded-lg border border-zinc-200 bg-white p-4">
            <h2 class="text-base font-semibold text-zinc-950">Attributes</h2>
            <pre class="mt-3 overflow-auto rounded-md bg-zinc-950 p-3 text-xs text-white"><%= inspect(@node.attributes, pretty: true) %></pre>
          </section>
        </aside>
      </div>

      <section class="grid gap-6 xl:grid-cols-2">
        <div class="rounded-lg border border-zinc-200 bg-white p-5">
          <h2 class="text-base font-semibold text-zinc-950">Outgoing</h2>
          <div class="mt-4 space-y-2">
            <div
              :for={relationship <- outgoing(@node)}
              class="rounded-lg border border-zinc-200 p-3 text-sm"
            >
              <p class="font-medium text-zinc-950">
                {relationship.type_key} -> {relationship.to_node && relationship.to_node.title}
              </p>
              <p class="mt-1 text-xs text-zinc-500">confidence {relationship.confidence}</p>
            </div>
            <p :if={outgoing(@node) == []} class="text-sm text-zinc-500">
              No outgoing relationships.
            </p>
          </div>
        </div>

        <div class="rounded-lg border border-zinc-200 bg-white p-5">
          <h2 class="text-base font-semibold text-zinc-950">Incoming</h2>
          <div class="mt-4 space-y-2">
            <div
              :for={relationship <- incoming(@node)}
              class="rounded-lg border border-zinc-200 p-3 text-sm"
            >
              <p class="font-medium text-zinc-950">
                {relationship.from_node && relationship.from_node.title} -> {relationship.type_key}
              </p>
              <p class="mt-1 text-xs text-zinc-500">confidence {relationship.confidence}</p>
            </div>
            <p :if={incoming(@node) == []} class="text-sm text-zinc-500">
              No incoming relationships.
            </p>
          </div>
        </div>
      </section>
    </section>
    """
  end
end
