defmodule HydraAgentWeb.GraphWorkbenchLive do
  use HydraAgentWeb, :live_view

  alias HydraAgent.{Knowledge, Runtime}
  alias HydraAgentWeb.ControlShell

  @node_statuses ~w(all draft active verified conflicted superseded archived)

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Graph Workbench")
     |> assign(:workspace_id, nil)
     |> assign(:node_type, "")
     |> assign(:node_status, "all")
     |> assign(:relationship_type, "")
     |> assign(:provenance, "")
     |> assign(:node_statuses, @node_statuses)
     |> load_workspaces()}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    workspace_id = selected_workspace_id(socket.assigns.workspaces, params["workspace_id"])

    socket =
      socket
      |> assign(:workspace_id, workspace_id)
      |> assign(:node_type, Map.get(params, "node_type", ""))
      |> assign(:node_status, node_status_param(params["node_status"]))
      |> assign(:relationship_type, Map.get(params, "relationship_type", ""))
      |> assign(:provenance, Map.get(params, "provenance", ""))
      |> load_workspace_state()

    {:noreply, socket}
  end

  @impl true
  def handle_event("filter-graph", params, socket) do
    params = stringify_keys(params)

    {:noreply,
     push_patch(socket,
       to:
         ~p"/control/graph?workspace_id=#{socket.assigns.workspace_id}&node_type=#{Map.get(params, "node_type", "")}&node_status=#{node_status_param(params["node_status"])}&relationship_type=#{Map.get(params, "relationship_type", "")}&provenance=#{Map.get(params, "provenance", "")}"
     )}
  end

  def handle_event("update-node", %{"node_id" => id} = params, socket) do
    result =
      id
      |> parse_id()
      |> Knowledge.get_node!()
      |> Knowledge.update_node(
        params
        |> stringify_keys()
        |> Map.take(~w(status confidence importance))
      )

    socket = handle_graph_result(result, socket, "Graph node updated")

    {:noreply, load_workspace_state(socket)}
  end

  def handle_event("update-relationship", %{"relationship_id" => id} = params, socket) do
    params = stringify_keys(params)

    case parse_json_map(params["provenance"]) do
      {:ok, provenance} ->
        result =
          id
          |> parse_id()
          |> Knowledge.get_relationship!()
          |> Knowledge.update_relationship(
            params
            |> Map.take(~w(confidence))
            |> Map.put("provenance", provenance)
          )

        socket = handle_graph_result(result, socket, "Graph relationship updated")

        {:noreply, load_workspace_state(socket)}

      {:error, message} ->
        {:noreply, put_flash(socket, :error, "Graph update failed: #{message}")}
    end
  end

  def handle_event("bulk-review-nodes", params, socket) do
    params = stringify_keys(params)
    reviewable_nodes = bulk_reviewable_nodes(socket.assigns.nodes)
    reviewed_at = now_iso8601()

    results =
      Enum.map(reviewable_nodes, fn node ->
        Knowledge.update_node(node, %{
          status: "verified",
          attributes:
            Map.merge(node.attributes || %{}, %{
              "reviewed_at" => reviewed_at,
              "reviewed_actor" => "graph_workbench",
              "reviewed_reason" => Map.get(params, "reason", ""),
              "reviewed_source" => "bulk_graph_review"
            })
        })
      end)

    failures = Enum.reject(results, &match?({:ok, _node}, &1))

    socket =
      if failures == [] do
        put_flash(socket, :info, "Verified #{length(results)} filtered graph nodes")
      else
        put_flash(socket, :error, "Graph bulk review failed for #{length(failures)} nodes")
      end

    {:noreply, load_workspace_state(socket)}
  end

  def handle_event("bulk-review-relationships", params, socket) do
    params = stringify_keys(params)
    reviewed_at = now_iso8601()
    confidence = parse_score(params["confidence"], 0.9)

    results =
      Enum.map(socket.assigns.relationships, fn relationship ->
        Knowledge.update_relationship(relationship, %{
          confidence: confidence,
          provenance:
            Map.merge(relationship.provenance || %{}, %{
              "reviewed_at" => reviewed_at,
              "reviewed_actor" => "graph_workbench",
              "reviewed_reason" => Map.get(params, "reason", ""),
              "reviewed_source" => "bulk_relationship_review"
            })
        })
      end)

    failures = Enum.reject(results, &match?({:ok, _relationship}, &1))

    socket =
      if failures == [] do
        put_flash(socket, :info, "Reviewed #{length(results)} filtered graph relationships")
      else
        put_flash(
          socket,
          :error,
          "Graph relationship bulk review failed for #{length(failures)} edges"
        )
      end

    {:noreply, load_workspace_state(socket)}
  end

  defp load_workspaces(socket) do
    assign(socket, :workspaces, Runtime.list_workspaces())
  end

  defp load_workspace_state(%{assigns: %{workspace_id: nil}} = socket) do
    socket
    |> assign(:nodes, [])
    |> assign(:relationships, [])
    |> assign(:relationships_by_node, %{})
    |> assign(:node_types, [])
    |> assign(:relationship_types, [])
  end

  defp load_workspace_state(
         %{
           assigns: %{
             workspace_id: workspace_id,
             node_type: node_type,
             node_status: node_status,
             relationship_type: relationship_type,
             provenance: provenance
           }
         } = socket
       ) do
    all_nodes = Knowledge.list_nodes(workspace_id, limit: 250)
    all_relationships = Knowledge.list_relationships(workspace_id, limit: 250)

    nodes =
      all_nodes
      |> filter_type(node_type)
      |> filter_status(node_status)
      |> filter_provenance(provenance)
      |> Enum.take(80)

    relationships =
      all_relationships
      |> filter_type(relationship_type)
      |> filter_provenance(provenance)
      |> Enum.take(80)

    socket
    |> assign(:nodes, nodes)
    |> assign(:relationships, relationships)
    |> assign(:relationships_by_node, relationships_by_node(all_relationships))
    |> assign(:node_types, type_options(all_nodes))
    |> assign(:relationship_types, type_options(all_relationships))
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

  defp filter_type(records, ""), do: records
  defp filter_type(records, type_key), do: Enum.filter(records, &(&1.type_key == type_key))

  defp filter_status(records, "all"), do: records
  defp filter_status(records, status), do: Enum.filter(records, &(&1.status == status))

  defp filter_provenance(records, ""), do: records

  defp filter_provenance(records, query) do
    query = String.downcase(query)

    Enum.filter(records, fn record ->
      record.provenance
      |> Jason.encode!()
      |> String.downcase()
      |> String.contains?(query)
    end)
  end

  defp type_options(records) do
    records
    |> Enum.map(& &1.type_key)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp parse_id(id) when is_integer(id), do: id

  defp parse_id(id) when is_binary(id) do
    case Integer.parse(id) do
      {parsed, ""} -> parsed
      _other -> nil
    end
  end

  defp parse_id(_id), do: nil

  defp handle_graph_result({:ok, _record}, socket, message), do: put_flash(socket, :info, message)

  defp handle_graph_result({:error, %Ecto.Changeset{} = changeset}, socket, _message),
    do: put_flash(socket, :error, "Graph update failed: #{inspect(changeset.errors)}")

  defp bulk_reviewable_nodes(nodes) do
    Enum.filter(nodes, &(&1.status in ["draft", "active"]))
  end

  defp node_status_param(status) when status in @node_statuses, do: status
  defp node_status_param(_status), do: "all"

  defp provenance_kind(%{provenance: %{"kind" => kind}}) when is_binary(kind), do: kind
  defp provenance_kind(_record), do: "manual"

  defp relationship_label(relationship) do
    from_title = relationship.from_node && relationship.from_node.title
    to_title = relationship.to_node && relationship.to_node.title

    "#{from_title || "unknown"} #{relationship.type_key} #{to_title || "unknown"}"
  end

  defp relationships_by_node(relationships) do
    Enum.reduce(relationships, %{}, fn relationship, acc ->
      acc
      |> Map.update({relationship.from_node_id, :outgoing}, [relationship], &[relationship | &1])
      |> Map.update({relationship.to_node_id, :incoming}, [relationship], &[relationship | &1])
    end)
  end

  defp node_relationships(node, relationships_by_node, direction) do
    relationships_by_node
    |> Map.get({node.id, direction}, [])
    |> Enum.reverse()
  end

  defp compact_json(map) when map in [%{}, nil], do: "{}"

  defp compact_json(map) when is_map(map) do
    map
    |> Jason.encode!()
    |> String.slice(0, 420)
  end

  defp parse_json_map(value) do
    value = String.trim(to_string(value || "{}"))

    case Jason.decode(if(value == "", do: "{}", else: value)) do
      {:ok, map} when is_map(map) -> {:ok, map}
      {:ok, _value} -> {:error, "provenance must be a JSON object"}
      {:error, _error} -> {:error, "provenance must be valid JSON"}
    end
  end

  defp parse_score(value, fallback) do
    case Float.parse(to_string(value || "")) do
      {score, ""} when score >= 0.0 and score <= 1.0 -> score
      _invalid -> fallback
    end
  end

  defp provenance_run_id(record) do
    case record.provenance["run_id"] || record.provenance[:run_id] do
      id when is_integer(id) -> id
      id when is_binary(id) -> id
      _id -> nil
    end
  end

  defp stringify_keys(map) when is_map(map),
    do: Map.new(map, fn {key, value} -> {to_string(key), value} end)

  defp now_iso8601 do
    DateTime.utc_now()
    |> DateTime.truncate(:microsecond)
    |> DateTime.to_iso8601()
  end

  @impl true
  def render(assigns) do
    ~H"""
    <section id="graph-workbench" class="space-y-8">
      <ControlShell.header
        active={:graph}
        description="Filter graph facts and relationships by type, status, and provenance evidence."
        eyebrow="Knowledge graph"
        query={
          %{
            node_type: @node_type,
            node_status: @node_status,
            relationship_type: @relationship_type,
            provenance: @provenance
          }
        }
        title="Graph Workbench"
        workspaces={@workspaces}
        workspace_id={@workspace_id}
      />

      <%= if @workspace_id do %>
        <form
          id="graph-filter-form"
          phx-change="filter-graph"
          class="grid gap-3 rounded-lg border border-zinc-200 bg-white p-4 md:grid-cols-4"
        >
          <select
            id="graph-node-type"
            name="node_type"
            class="rounded-md border border-zinc-200 px-3 py-2 text-sm text-zinc-700 focus:border-zinc-400 focus:outline-none"
          >
            <option value="" selected={@node_type == ""}>all node types</option>
            <option :for={type <- @node_types} value={type} selected={type == @node_type}>
              {type}
            </option>
          </select>
          <select
            id="graph-node-status"
            name="node_status"
            class="rounded-md border border-zinc-200 px-3 py-2 text-sm text-zinc-700 focus:border-zinc-400 focus:outline-none"
          >
            <option :for={status <- @node_statuses} value={status} selected={status == @node_status}>
              {status}
            </option>
          </select>
          <select
            id="graph-relationship-type"
            name="relationship_type"
            class="rounded-md border border-zinc-200 px-3 py-2 text-sm text-zinc-700 focus:border-zinc-400 focus:outline-none"
          >
            <option value="" selected={@relationship_type == ""}>all relationship types</option>
            <option
              :for={type <- @relationship_types}
              value={type}
              selected={type == @relationship_type}
            >
              {type}
            </option>
          </select>
          <input
            id="graph-provenance"
            name="provenance"
            type="search"
            value={@provenance}
            placeholder="Provenance contains"
            class="rounded-md border border-zinc-200 px-3 py-2 text-sm text-zinc-700 placeholder:text-zinc-400 focus:border-zinc-400 focus:outline-none"
          />
        </form>

        <div class="grid gap-4 md:grid-cols-2">
          <div class="rounded-lg border border-zinc-200 bg-white p-4">
            <p class="text-xs font-semibold uppercase tracking-[0.14em] text-zinc-500">Nodes</p>
            <p class="mt-3 text-3xl font-semibold text-zinc-950">{length(@nodes)}</p>
            <p class="mt-1 text-sm text-zinc-600">matching facts and memories</p>
          </div>
          <div class="rounded-lg border border-zinc-200 bg-white p-4">
            <p class="text-xs font-semibold uppercase tracking-[0.14em] text-zinc-500">
              Relationships
            </p>
            <p class="mt-3 text-3xl font-semibold text-zinc-950">{length(@relationships)}</p>
            <p class="mt-1 text-sm text-zinc-600">matching graph edges</p>
          </div>
        </div>

        <div class="grid gap-6 xl:grid-cols-2">
          <section class="space-y-3">
            <div class="flex flex-wrap items-end justify-between gap-3">
              <div>
                <h2 class="text-lg font-semibold text-zinc-950">Nodes</h2>
                <p class="mt-1 text-sm text-zinc-600">
                  {length(bulk_reviewable_nodes(@nodes))} filtered draft/active nodes ready for bulk review
                </p>
              </div>
              <form
                id="graph-bulk-node-review-form"
                phx-submit="bulk-review-nodes"
                class="flex flex-wrap items-center gap-2"
              >
                <input
                  id="graph-bulk-node-review-reason"
                  name="reason"
                  type="text"
                  placeholder="Review reason"
                  class="w-52 rounded-md border border-zinc-200 px-2 py-1 text-xs text-zinc-700 placeholder:text-zinc-400 focus:border-zinc-400 focus:outline-none"
                />
                <button
                  id="graph-bulk-node-review-submit"
                  type="submit"
                  disabled={bulk_reviewable_nodes(@nodes) == []}
                  class={[
                    "rounded-md border px-2 py-1 text-xs font-medium transition",
                    bulk_reviewable_nodes(@nodes) == [] &&
                      "cursor-not-allowed border-zinc-100 text-zinc-300",
                    bulk_reviewable_nodes(@nodes) != [] &&
                      "border-zinc-200 text-zinc-700 hover:border-zinc-400"
                  ]}
                >
                  Verify Filtered
                </button>
              </form>
            </div>
            <div id="graph-nodes" class="space-y-2">
              <div
                :for={node <- @nodes}
                id={"graph-node-#{node.id}"}
                class="rounded-lg border border-zinc-200 bg-white p-4"
              >
                <div class="flex items-start justify-between gap-3">
                  <div class="min-w-0">
                    <p class="text-xs font-semibold uppercase tracking-[0.12em] text-zinc-500">
                      {node.type_key}
                    </p>
                    <p class="mt-2 truncate text-sm font-semibold text-zinc-950">{node.title}</p>
                    <p class="mt-1 line-clamp-2 text-sm text-zinc-600">{node.body}</p>
                  </div>
                  <span class="text-xs font-medium uppercase text-zinc-500">{node.status}</span>
                </div>
                <p class="mt-3 text-xs text-zinc-500">
                  confidence {node.confidence} / importance {node.importance} / provenance {provenance_kind(
                    node
                  )}
                </p>
                <form
                  id={"graph-node-settings-form-#{node.id}"}
                  phx-submit="update-node"
                  class="mt-3 grid gap-2"
                >
                  <input type="hidden" name="node_id" value={node.id} />
                  <div class="grid gap-2 md:grid-cols-3">
                    <select
                      id={"graph-node-status-#{node.id}"}
                      name="status"
                      class="w-full rounded-md border border-zinc-200 px-2 py-1 text-xs text-zinc-700 focus:border-zinc-400 focus:outline-none"
                    >
                      <option
                        :for={status <- @node_statuses -- ["all"]}
                        value={status}
                        selected={status == node.status}
                      >
                        {status}
                      </option>
                    </select>
                    <input
                      id={"graph-node-confidence-#{node.id}"}
                      name="confidence"
                      type="number"
                      min="0"
                      max="1"
                      step="0.01"
                      value={node.confidence}
                      class="w-full rounded-md border border-zinc-200 px-2 py-1 text-xs text-zinc-700 focus:border-zinc-400 focus:outline-none"
                    />
                    <input
                      id={"graph-node-importance-#{node.id}"}
                      name="importance"
                      type="number"
                      min="0"
                      max="1"
                      step="0.01"
                      value={node.importance}
                      class="w-full rounded-md border border-zinc-200 px-2 py-1 text-xs text-zinc-700 focus:border-zinc-400 focus:outline-none"
                    />
                  </div>
                  <button
                    id={"graph-node-settings-save-#{node.id}"}
                    type="submit"
                    class="w-fit rounded-md border border-zinc-200 px-2 py-1 text-xs font-medium text-zinc-700 transition hover:border-zinc-400"
                  >
                    Save Node
                  </button>
                </form>
                <div class="mt-3 grid gap-3 border-t border-zinc-100 pt-3 md:grid-cols-2">
                  <div>
                    <p class="text-xs font-semibold uppercase tracking-[0.12em] text-zinc-500">
                      Outgoing
                    </p>
                    <p
                      :for={
                        relationship <- node_relationships(node, @relationships_by_node, :outgoing)
                      }
                      class="mt-1 text-xs text-zinc-600"
                    >
                      {relationship.type_key} {relationship.to_node && relationship.to_node.title}
                    </p>
                    <p
                      :if={node_relationships(node, @relationships_by_node, :outgoing) == []}
                      class="mt-1 text-xs text-zinc-500"
                    >
                      none
                    </p>
                  </div>
                  <div>
                    <p class="text-xs font-semibold uppercase tracking-[0.12em] text-zinc-500">
                      Incoming
                    </p>
                    <p
                      :for={
                        relationship <- node_relationships(node, @relationships_by_node, :incoming)
                      }
                      class="mt-1 text-xs text-zinc-600"
                    >
                      {relationship.from_node && relationship.from_node.title} {relationship.type_key}
                    </p>
                    <p
                      :if={node_relationships(node, @relationships_by_node, :incoming) == []}
                      class="mt-1 text-xs text-zinc-500"
                    >
                      none
                    </p>
                  </div>
                </div>
                <div class="mt-3 border-t border-zinc-100 pt-3">
                  <div class="flex flex-wrap items-center justify-between gap-2">
                    <p class="text-xs font-semibold uppercase tracking-[0.12em] text-zinc-500">
                      Provenance
                    </p>
                    <.link
                      :if={provenance_run_id(node)}
                      navigate={~p"/control/runs/#{provenance_run_id(node)}"}
                      class="text-xs font-semibold text-zinc-950 underline decoration-zinc-300 underline-offset-2 hover:decoration-zinc-950"
                    >
                      Open source run
                    </.link>
                  </div>
                  <p class="mt-1 break-words font-mono text-xs text-zinc-500">
                    {compact_json(node.provenance)}
                  </p>
                </div>
              </div>
              <div
                :if={@nodes == []}
                class="rounded-lg border border-zinc-200 bg-white p-4 text-sm text-zinc-500"
              >
                No graph nodes match these filters.
              </div>
            </div>
          </section>

          <section class="space-y-3">
            <div class="flex flex-wrap items-end justify-between gap-3">
              <div>
                <h2 class="text-lg font-semibold text-zinc-950">Relationships</h2>
                <p class="mt-1 text-sm text-zinc-600">
                  {length(@relationships)} filtered relationships ready for bulk review
                </p>
              </div>
              <form
                id="graph-bulk-relationship-review-form"
                phx-submit="bulk-review-relationships"
                class="flex flex-wrap items-center gap-2"
              >
                <input
                  id="graph-bulk-relationship-review-reason"
                  name="reason"
                  type="text"
                  placeholder="Review reason"
                  class="w-52 rounded-md border border-zinc-200 px-2 py-1 text-xs text-zinc-700 placeholder:text-zinc-400 focus:border-zinc-400 focus:outline-none"
                />
                <input
                  id="graph-bulk-relationship-confidence"
                  name="confidence"
                  type="number"
                  min="0"
                  max="1"
                  step="0.01"
                  value="0.9"
                  class="w-24 rounded-md border border-zinc-200 px-2 py-1 text-xs text-zinc-700 focus:border-zinc-400 focus:outline-none"
                />
                <button
                  id="graph-bulk-relationship-review-submit"
                  type="submit"
                  disabled={@relationships == []}
                  class={[
                    "rounded-md border px-2 py-1 text-xs font-medium transition",
                    @relationships == [] && "cursor-not-allowed border-zinc-100 text-zinc-300",
                    @relationships != [] && "border-zinc-200 text-zinc-700 hover:border-zinc-400"
                  ]}
                >
                  Review Filtered
                </button>
              </form>
            </div>
            <div id="graph-relationships" class="space-y-2">
              <div
                :for={relationship <- @relationships}
                id={"graph-relationship-#{relationship.id}"}
                class="rounded-lg border border-zinc-200 bg-white p-4"
              >
                <p class="text-sm font-semibold text-zinc-950">
                  {relationship_label(relationship)}
                </p>
                <p class="mt-1 text-xs text-zinc-500">
                  confidence {relationship.confidence} / provenance {provenance_kind(relationship)}
                </p>
                <form
                  id={"graph-relationship-settings-form-#{relationship.id}"}
                  phx-submit="update-relationship"
                  class="mt-3 grid gap-2"
                >
                  <input type="hidden" name="relationship_id" value={relationship.id} />
                  <div class="flex flex-wrap items-end gap-2">
                    <input
                      id={"graph-relationship-confidence-#{relationship.id}"}
                      name="confidence"
                      type="number"
                      min="0"
                      max="1"
                      step="0.01"
                      value={relationship.confidence}
                      class="w-28 rounded-md border border-zinc-200 px-2 py-1 text-xs text-zinc-700 focus:border-zinc-400 focus:outline-none"
                    />
                    <button
                      id={"graph-relationship-settings-save-#{relationship.id}"}
                      type="submit"
                      class="rounded-md border border-zinc-200 px-2 py-1 text-xs font-medium text-zinc-700 transition hover:border-zinc-400"
                    >
                      Save Relationship
                    </button>
                  </div>
                  <textarea
                    id={"graph-relationship-provenance-#{relationship.id}"}
                    name="provenance"
                    rows="3"
                    class="w-full rounded-md border border-zinc-200 px-2 py-1 font-mono text-xs text-zinc-700 focus:border-zinc-400 focus:outline-none"
                  ><%= compact_json(relationship.provenance) %></textarea>
                </form>
                <div class="mt-3 border-t border-zinc-100 pt-3">
                  <div class="flex flex-wrap items-center justify-between gap-2">
                    <p class="text-xs font-semibold uppercase tracking-[0.12em] text-zinc-500">
                      Evidence
                    </p>
                    <.link
                      :if={provenance_run_id(relationship)}
                      navigate={~p"/control/runs/#{provenance_run_id(relationship)}"}
                      class="text-xs font-semibold text-zinc-950 underline decoration-zinc-300 underline-offset-2 hover:decoration-zinc-950"
                    >
                      Open source run
                    </.link>
                  </div>
                  <p class="mt-1 break-words font-mono text-xs text-zinc-500">
                    {compact_json(relationship.provenance)}
                  </p>
                </div>
              </div>
              <div
                :if={@relationships == []}
                class="rounded-lg border border-zinc-200 bg-white p-4 text-sm text-zinc-500"
              >
                No graph relationships match these filters.
              </div>
            </div>
          </section>
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
