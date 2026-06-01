defmodule HydraAgentWeb.MemoryStudioLive do
  use HydraAgentWeb, :live_view

  alias HydraAgent.{Knowledge, Memory, Runtime}
  alias HydraAgentWeb.ControlShell

  @statuses ~w(active verified conflicted superseded archived all)
  @memory_statuses ~w(active verified conflicted superseded archived)
  @default_archive_below_confidence 0.2

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Memory Studio")
     |> assign(:workspace_id, nil)
     |> assign(:q, "")
     |> assign(:status, "active")
     |> assign(:archive_below_confidence, @default_archive_below_confidence)
     |> assign(:statuses, @statuses)
     |> assign(:memory_statuses, @memory_statuses)
     |> load_workspaces()}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    workspace_id = selected_workspace_id(socket.assigns.workspaces, params["workspace_id"])
    q = Map.get(params, "q", "")
    status = status_param(params["status"])
    archive_below_confidence = threshold_param(params["archive_below_confidence"])

    socket =
      socket
      |> assign(:workspace_id, workspace_id)
      |> assign(:q, q)
      |> assign(:status, status)
      |> assign(:archive_below_confidence, archive_below_confidence)
      |> load_workspace_state()

    {:noreply, socket}
  end

  @impl true
  def handle_event("filter-memory", params, socket) do
    params = stringify_keys(params)

    {:noreply,
     push_patch(socket,
       to:
         ~p"/control/memory?workspace_id=#{socket.assigns.workspace_id}&q=#{Map.get(params, "q", "")}&status=#{status_param(params["status"])}&archive_below_confidence=#{socket.assigns.archive_below_confidence}"
     )}
  end

  def handle_event("set-curation-threshold", params, socket) do
    params = stringify_keys(params)
    threshold = threshold_param(params["archive_below_confidence"])

    {:noreply,
     push_patch(socket,
       to:
         ~p"/control/memory?workspace_id=#{socket.assigns.workspace_id}&q=#{socket.assigns.q}&status=#{socket.assigns.status}&archive_below_confidence=#{threshold}"
     )}
  end

  def handle_event(
        "review-memory",
        %{"decision" => decision, "proposal_id" => id} = params,
        socket
      )
      when decision in ["promote", "reject"] do
    attrs = %{"actor" => "memory_studio", "reason" => Map.get(params, "reason", "")}

    result =
      case decision do
        "promote" -> id |> parse_id() |> Memory.promote_proposal(attrs)
        "reject" -> id |> parse_id() |> Memory.reject_proposal(attrs)
      end

    message = if decision == "promote", do: "Memory promoted", else: "Memory rejected"
    socket = handle_memory_result(result, socket, message)

    {:noreply, load_workspace_state(socket)}
  end

  def handle_event("update-proposal", %{"proposal_id" => id} = params, socket) do
    attrs =
      params
      |> stringify_keys()
      |> Map.take(~w(title body confidence importance))
      |> Map.put("actor", "memory_studio")

    socket =
      id
      |> parse_id()
      |> Memory.update_proposal_draft(attrs)
      |> handle_memory_result(socket, "Memory proposal updated")

    {:noreply, load_workspace_state(socket)}
  end

  def handle_event("update-memory", %{"memory_id" => id} = params, socket) do
    attrs =
      params
      |> stringify_keys()
      |> Map.take(~w(status confidence importance))
      |> Map.put("actor", "memory_studio")

    socket =
      id
      |> parse_id()
      |> Memory.update_memory_node(attrs)
      |> handle_memory_result(socket, "Memory updated")

    {:noreply, load_workspace_state(socket)}
  end

  def handle_event("archive-memory", %{"id" => id}, socket) do
    socket =
      id
      |> parse_id()
      |> Memory.archive_node(%{"actor" => "memory_studio", "reason" => "operator_archive"})
      |> handle_memory_result(socket, "Memory archived")

    {:noreply, load_workspace_state(socket)}
  end

  def handle_event("archive-low-confidence", _params, socket) do
    result =
      Memory.curate_workspace(socket.assigns.workspace_id,
        dry_run?: false,
        archive_below_confidence: socket.assigns.archive_below_confidence,
        archive_low_confidence?: true,
        resolve_duplicates?: false,
        actor: "memory_studio"
      )

    archived_count = length(result["archived_node_ids"])

    socket =
      socket
      |> put_flash(:info, "Archived #{archived_count} low-confidence memories")
      |> load_workspace_state()

    {:noreply, socket}
  end

  def handle_event("archive-duplicate-memories", _params, socket) do
    result =
      Memory.curate_workspace(socket.assigns.workspace_id,
        dry_run?: false,
        archive_below_confidence: socket.assigns.archive_below_confidence,
        archive_low_confidence?: false,
        resolve_duplicates?: true,
        actor: "memory_studio"
      )

    archived_count = length(result["archived_duplicate_node_ids"])

    socket =
      socket
      |> put_flash(:info, "Archived #{archived_count} duplicate memories")
      |> load_workspace_state()

    {:noreply, socket}
  end

  defp load_workspaces(socket) do
    assign(socket, :workspaces, Runtime.list_workspaces())
  end

  defp load_workspace_state(%{assigns: %{workspace_id: nil}} = socket) do
    socket
    |> assign(:proposals, [])
    |> assign(:memories, [])
    |> assign(:memory_conflicts, %{})
    |> assign(:conflict_count, 0)
    |> assign(:curation, %{
      "low_confidence_candidates" => [],
      "duplicate_title_groups" => [],
      "archived_node_ids" => [],
      "archived_duplicate_node_ids" => []
    })
  end

  defp load_workspace_state(
         %{
           assigns: %{
             workspace_id: workspace_id,
             q: q,
             status: status,
             archive_below_confidence: archive_below_confidence
           }
         } = socket
       ) do
    memories = list_memories(workspace_id, q, status)
    proposals = Memory.list_proposals(workspace_id, limit: 20)

    curation =
      Memory.curate_workspace(workspace_id,
        dry_run?: true,
        archive_below_confidence: archive_below_confidence
      )

    conflict_relationships = conflict_relationships(workspace_id)

    socket
    |> assign(:memories, memories)
    |> assign(:proposals, proposals)
    |> assign(:memory_conflicts, memory_conflicts(conflict_relationships))
    |> assign(:conflict_count, length(conflict_relationships))
    |> assign(:curation, curation)
  end

  defp list_memories(workspace_id, q, status) do
    nodes =
      if String.trim(to_string(q || "")) == "" do
        Knowledge.list_nodes(workspace_id, type_key: "memory", limit: 100)
      else
        Knowledge.search_nodes(workspace_id, q, limit: 100)
        |> Enum.filter(&(&1.type_key == "memory"))
      end

    nodes
    |> Enum.reject(&pending_proposal?/1)
    |> Enum.filter(&(status == "all" or &1.status == status))
  end

  defp conflict_relationships(workspace_id) do
    workspace_id
    |> Knowledge.list_relationships(type_key: "contradicts", limit: 250)
    |> Enum.filter(&(memory_node?(&1.from_node) or memory_node?(&1.to_node)))
  end

  defp memory_conflicts(relationships) do
    Enum.reduce(relationships, %{}, fn relationship, acc ->
      acc
      |> maybe_add_conflict(relationship.from_node, relationship)
      |> maybe_add_conflict(relationship.to_node, relationship)
    end)
  end

  defp maybe_add_conflict(acc, %{type_key: "memory", id: node_id}, relationship),
    do: Map.update(acc, node_id, [relationship], &[relationship | &1])

  defp maybe_add_conflict(acc, _node, _relationship), do: acc

  defp memory_node?(%{type_key: "memory"}), do: true
  defp memory_node?(_node), do: false

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

  defp handle_memory_result({:ok, _node}, socket, message), do: put_flash(socket, :info, message)

  defp handle_memory_result({:error, %Ecto.Changeset{} = changeset}, socket, _message),
    do: put_flash(socket, :error, "Memory update failed: #{inspect(changeset.errors)}")

  defp handle_memory_result({:error, %{} = error}, socket, _message),
    do: put_flash(socket, :error, "Memory update failed: #{inspect(error)}")

  defp parse_id(id) when is_integer(id), do: id

  defp parse_id(id) when is_binary(id) do
    case Integer.parse(id) do
      {parsed, ""} -> parsed
      _other -> nil
    end
  end

  defp parse_id(_id), do: nil

  defp pending_proposal?(node) do
    node.provenance["kind"] == "memory_proposal" and
      node.attributes["proposal_status"] == "pending"
  end

  defp proposal_kind(node), do: node.provenance["kind"] || "manual"

  defp node_conflicts(node, memory_conflicts), do: Map.get(memory_conflicts, node.id, [])

  defp conflict_label(relationship) do
    from_title = relationship.from_node && relationship.from_node.title
    to_title = relationship.to_node && relationship.to_node.title

    "#{from_title || "unknown"} contradicts #{to_title || "unknown"}"
  end

  defp conflict_provenance(relationship), do: relationship.provenance["kind"] || "manual"

  defp memory_history(node) do
    attributes = node.attributes || %{}
    provenance = node.provenance || %{}

    []
    |> add_review_history(provenance["reviews"])
    |> add_attribute_history("reviewed", attributes["reviewed_at"], attributes["review_actor"],
      detail: attributes["review_reason"]
    )
    |> add_attribute_history("edited", attributes["edited_at"], attributes["edited_actor"])
    |> add_attribute_history("archived", attributes["archived_at"], attributes["archived_actor"],
      detail: attributes["archived_reason"]
    )
    |> Enum.reject(&is_nil/1)
  end

  defp add_review_history(items, reviews) when is_list(reviews) do
    review_items =
      Enum.map(reviews, fn review ->
        %{
          label: "review #{review["decision"] || "recorded"}",
          at: review["reviewed_at"],
          actor: review["review_actor"] || "operator",
          detail: review["review_reason"]
        }
      end)

    items ++ review_items
  end

  defp add_review_history(items, _reviews), do: items

  defp add_attribute_history(items, label, at, actor, opts \\ [])

  defp add_attribute_history(items, _label, nil, _actor, _opts), do: items

  defp add_attribute_history(items, label, at, actor, opts) do
    items ++
      [
        %{
          label: label,
          at: at,
          actor: actor || "operator",
          detail: Keyword.get(opts, :detail)
        }
      ]
  end

  defp status_param(status) when status in @statuses, do: status
  defp status_param(_status), do: "active"

  defp threshold_param(value) do
    case Float.parse(to_string(value || "")) do
      {threshold, ""} when threshold >= 0.0 and threshold <= 1.0 ->
        threshold

      _invalid ->
        @default_archive_below_confidence
    end
  end

  defp percent(nil), do: "n/a"
  defp percent(value), do: "#{Float.round(value * 100, 1)}%"

  defp stringify_keys(map) when is_map(map),
    do: Map.new(map, fn {key, value} -> {to_string(key), value} end)

  @impl true
  def render(assigns) do
    ~H"""
    <section id="memory-studio" class="space-y-8">
      <ControlShell.header
        active={:memory}
        description="Review proposed memories, inspect durable recall material, and archive low-signal entries."
        eyebrow="Learning loop"
        query={%{q: @q, status: @status}}
        title="Memory Studio"
        workspaces={@workspaces}
        workspace_id={@workspace_id}
      />

      <%= if @workspace_id do %>
        <form
          id="memory-filter-form"
          phx-change="filter-memory"
          class="grid gap-3 rounded-lg border border-zinc-200 bg-white p-4 md:grid-cols-[1fr_180px]"
        >
          <input
            id="memory-filter-q"
            name="q"
            type="search"
            value={@q}
            placeholder="Search memory"
            class="rounded-md border border-zinc-200 px-3 py-2 text-sm text-zinc-700 placeholder:text-zinc-400 focus:border-zinc-400 focus:outline-none"
          />
          <select
            id="memory-filter-status"
            name="status"
            class="rounded-md border border-zinc-200 px-3 py-2 text-sm text-zinc-700 focus:border-zinc-400 focus:outline-none"
          >
            <option :for={status <- @statuses} value={status} selected={status == @status}>
              {status}
            </option>
          </select>
        </form>

        <div class="grid gap-4 md:grid-cols-4">
          <div class="rounded-lg border border-zinc-200 bg-white p-4">
            <p class="text-xs font-semibold uppercase tracking-[0.14em] text-zinc-500">Proposals</p>
            <p class="mt-3 text-3xl font-semibold text-zinc-950">{length(@proposals)}</p>
            <p class="mt-1 text-sm text-zinc-600">pending review</p>
          </div>
          <div class="rounded-lg border border-zinc-200 bg-white p-4">
            <p class="text-xs font-semibold uppercase tracking-[0.14em] text-zinc-500">Memories</p>
            <p class="mt-3 text-3xl font-semibold text-zinc-950">{length(@memories)}</p>
            <p class="mt-1 text-sm text-zinc-600">{@status} filter</p>
          </div>
          <div class="rounded-lg border border-zinc-200 bg-white p-4">
            <p class="text-xs font-semibold uppercase tracking-[0.14em] text-zinc-500">Curation</p>
            <p class="mt-3 text-3xl font-semibold text-zinc-950">
              {length(@curation["low_confidence_candidates"])}
            </p>
            <p class="mt-1 text-sm text-zinc-600">low-confidence candidates</p>
          </div>
          <div class="rounded-lg border border-zinc-200 bg-white p-4">
            <p class="text-xs font-semibold uppercase tracking-[0.14em] text-zinc-500">Conflicts</p>
            <p class="mt-3 text-3xl font-semibold text-zinc-950">{@conflict_count}</p>
            <p class="mt-1 text-sm text-zinc-600">contradictory memory links</p>
          </div>
        </div>

        <div class="grid gap-6 xl:grid-cols-[0.85fr_1.15fr]">
          <section class="space-y-3">
            <h2 class="text-lg font-semibold text-zinc-950">Proposal Queue</h2>
            <div id="memory-proposal-queue" class="space-y-2">
              <div
                :for={proposal <- @proposals}
                id={"memory-proposal-#{proposal.id}"}
                class="rounded-lg border border-zinc-200 bg-white p-4"
              >
                <p class="text-sm font-semibold text-zinc-950">{proposal.title}</p>
                <p class="mt-1 line-clamp-3 text-sm text-zinc-600">{proposal.body}</p>
                <p class="mt-2 text-xs text-zinc-500">
                  confidence {percent(proposal.confidence)} / importance {percent(proposal.importance)} / {proposal_kind(
                    proposal
                  )}
                </p>
                <form
                  id={"memory-proposal-edit-form-#{proposal.id}"}
                  phx-submit="update-proposal"
                  class="mt-3 grid gap-2"
                >
                  <input type="hidden" name="proposal_id" value={proposal.id} />
                  <input
                    id={"memory-proposal-title-#{proposal.id}"}
                    name="title"
                    type="text"
                    value={proposal.title}
                    class="w-full rounded-md border border-zinc-200 px-2 py-1 text-xs text-zinc-700 focus:border-zinc-400 focus:outline-none"
                  />
                  <textarea
                    id={"memory-proposal-body-#{proposal.id}"}
                    name="body"
                    rows="3"
                    class="w-full rounded-md border border-zinc-200 px-2 py-1 text-xs text-zinc-700 focus:border-zinc-400 focus:outline-none"
                  ><%= proposal.body %></textarea>
                  <div class="grid gap-2 md:grid-cols-2">
                    <input
                      id={"memory-proposal-confidence-#{proposal.id}"}
                      name="confidence"
                      type="number"
                      min="0"
                      max="1"
                      step="0.01"
                      value={proposal.confidence}
                      class="w-full rounded-md border border-zinc-200 px-2 py-1 text-xs text-zinc-700 focus:border-zinc-400 focus:outline-none"
                    />
                    <input
                      id={"memory-proposal-importance-#{proposal.id}"}
                      name="importance"
                      type="number"
                      min="0"
                      max="1"
                      step="0.01"
                      value={proposal.importance}
                      class="w-full rounded-md border border-zinc-200 px-2 py-1 text-xs text-zinc-700 focus:border-zinc-400 focus:outline-none"
                    />
                  </div>
                  <button
                    id={"memory-proposal-save-#{proposal.id}"}
                    type="submit"
                    class="w-fit rounded-md border border-zinc-200 px-2 py-1 text-xs font-medium text-zinc-700 transition hover:border-zinc-400"
                  >
                    Save Proposal
                  </button>
                </form>
                <form
                  id={"memory-review-form-#{proposal.id}"}
                  phx-submit="review-memory"
                  class="mt-3 space-y-2"
                >
                  <input type="hidden" name="proposal_id" value={proposal.id} />
                  <input
                    id={"memory-review-reason-#{proposal.id}"}
                    name="reason"
                    type="text"
                    placeholder="Review reason"
                    class="w-full rounded-md border border-zinc-200 px-2 py-1 text-xs text-zinc-700 placeholder:text-zinc-400 focus:border-zinc-400 focus:outline-none"
                  />
                  <div class="flex gap-2">
                    <button
                      id={"memory-promote-#{proposal.id}"}
                      type="submit"
                      name="decision"
                      value="promote"
                      class="rounded-md border border-emerald-200 px-2 py-1 text-xs font-medium text-emerald-700 transition hover:border-emerald-400"
                    >
                      Promote
                    </button>
                    <button
                      id={"memory-reject-#{proposal.id}"}
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
                :if={@proposals == []}
                class="rounded-lg border border-zinc-200 bg-white p-4 text-sm text-zinc-500"
              >
                No pending memory proposals.
              </div>
            </div>
          </section>

          <section class="space-y-3">
            <h2 class="text-lg font-semibold text-zinc-950">Durable Memory</h2>
            <div id="memory-results" class="grid gap-3 md:grid-cols-2">
              <div
                :for={memory <- @memories}
                id={"memory-result-#{memory.id}"}
                class="rounded-lg border border-zinc-200 bg-white p-4"
              >
                <div class="flex items-start justify-between gap-3">
                  <div class="min-w-0">
                    <p class="truncate text-sm font-semibold text-zinc-950">{memory.title}</p>
                    <p class="mt-1 line-clamp-3 text-sm text-zinc-600">{memory.body}</p>
                  </div>
                  <span class="text-xs font-medium uppercase text-zinc-500">{memory.status}</span>
                </div>
                <p class="mt-3 text-xs text-zinc-500">
                  confidence {percent(memory.confidence)} / importance {percent(memory.importance)} / {proposal_kind(
                    memory
                  )}
                </p>
                <div
                  :if={memory_history(memory) != []}
                  id={"memory-history-#{memory.id}"}
                  class="mt-3 space-y-2 rounded-md border border-zinc-100 bg-zinc-50 p-3"
                >
                  <p class="text-xs font-semibold uppercase tracking-[0.14em] text-zinc-500">
                    History
                  </p>
                  <div
                    :for={item <- memory_history(memory)}
                    class="text-xs text-zinc-600"
                  >
                    <p class="font-medium text-zinc-800">
                      {item.label} / {item.actor} / {item.at || "unknown time"}
                    </p>
                    <p :if={item.detail} class="mt-1">{item.detail}</p>
                  </div>
                </div>
                <div
                  :if={node_conflicts(memory, @memory_conflicts) != []}
                  id={"memory-conflicts-#{memory.id}"}
                  class="mt-3 space-y-2 rounded-md border border-amber-200 bg-amber-50 p-3"
                >
                  <p class="text-xs font-semibold uppercase tracking-[0.14em] text-amber-800">
                    Conflict Signals
                  </p>
                  <div
                    :for={relationship <- node_conflicts(memory, @memory_conflicts)}
                    id={"memory-conflict-#{memory.id}-#{relationship.id}"}
                    class="text-xs text-amber-900"
                  >
                    <p class="font-medium">{conflict_label(relationship)}</p>
                    <p class="mt-1 text-amber-800">
                      confidence {percent(relationship.confidence)} / provenance {conflict_provenance(
                        relationship
                      )}
                    </p>
                  </div>
                </div>
                <form
                  id={"memory-settings-form-#{memory.id}"}
                  phx-submit="update-memory"
                  class="mt-3 grid gap-2"
                >
                  <input type="hidden" name="memory_id" value={memory.id} />
                  <div class="grid gap-2 md:grid-cols-3">
                    <select
                      id={"memory-status-#{memory.id}"}
                      name="status"
                      class="w-full rounded-md border border-zinc-200 px-2 py-1 text-xs text-zinc-700 focus:border-zinc-400 focus:outline-none"
                    >
                      <option
                        :for={status <- @memory_statuses}
                        value={status}
                        selected={status == memory.status}
                      >
                        {status}
                      </option>
                    </select>
                    <input
                      id={"memory-confidence-#{memory.id}"}
                      name="confidence"
                      type="number"
                      min="0"
                      max="1"
                      step="0.01"
                      value={memory.confidence}
                      class="w-full rounded-md border border-zinc-200 px-2 py-1 text-xs text-zinc-700 focus:border-zinc-400 focus:outline-none"
                    />
                    <input
                      id={"memory-importance-#{memory.id}"}
                      name="importance"
                      type="number"
                      min="0"
                      max="1"
                      step="0.01"
                      value={memory.importance}
                      class="w-full rounded-md border border-zinc-200 px-2 py-1 text-xs text-zinc-700 focus:border-zinc-400 focus:outline-none"
                    />
                  </div>
                  <button
                    id={"memory-settings-save-#{memory.id}"}
                    type="submit"
                    class="w-fit rounded-md border border-zinc-200 px-2 py-1 text-xs font-medium text-zinc-700 transition hover:border-zinc-400"
                  >
                    Save Memory
                  </button>
                </form>
                <button
                  :if={memory.status != "archived"}
                  id={"memory-archive-#{memory.id}"}
                  type="button"
                  phx-click="archive-memory"
                  phx-value-id={memory.id}
                  class="mt-3 rounded-md border border-zinc-200 px-2 py-1 text-xs font-medium text-zinc-700 transition hover:border-zinc-400"
                >
                  Archive
                </button>
              </div>
              <div
                :if={@memories == []}
                class="rounded-lg border border-zinc-200 bg-white p-4 text-sm text-zinc-500"
              >
                No memory matches this filter.
              </div>
            </div>
          </section>
        </div>

        <section class="space-y-3">
          <h2 class="text-lg font-semibold text-zinc-950">Curation Signals</h2>
          <div id="memory-curation" class="grid gap-3 md:grid-cols-2">
            <div class="rounded-lg border border-zinc-200 bg-white p-4">
              <p class="text-sm font-semibold text-zinc-950">Low Confidence</p>
              <p class="mt-2 text-sm text-zinc-600">
                {length(@curation["low_confidence_candidates"])} candidates below current threshold
              </p>
              <form
                id="memory-curation-threshold-form"
                phx-change="set-curation-threshold"
                class="mt-3 flex flex-wrap items-center gap-2"
              >
                <label
                  for="memory-curation-threshold"
                  class="text-xs font-semibold uppercase tracking-[0.12em] text-zinc-500"
                >
                  Threshold
                </label>
                <input
                  id="memory-curation-threshold"
                  name="archive_below_confidence"
                  type="number"
                  min="0"
                  max="1"
                  step="0.01"
                  value={@archive_below_confidence}
                  class="w-24 rounded-md border border-zinc-200 px-2 py-1 text-xs text-zinc-700 focus:border-zinc-400 focus:outline-none"
                />
              </form>
              <div
                :if={@curation["low_confidence_candidates"] != []}
                id="memory-low-confidence-candidates"
                class="mt-3 space-y-2"
              >
                <div
                  :for={candidate <- Enum.take(@curation["low_confidence_candidates"], 4)}
                  id={"memory-low-confidence-candidate-#{candidate["id"]}"}
                  class="rounded-md border border-zinc-100 bg-zinc-50 p-2 text-xs text-zinc-600"
                >
                  <p class="font-medium text-zinc-800">{candidate["title"]}</p>
                  <p class="mt-1">
                    confidence {percent(candidate["confidence"])} / importance {percent(
                      candidate["importance"]
                    )}
                  </p>
                </div>
              </div>
              <button
                id="memory-archive-low-confidence"
                type="button"
                phx-click="archive-low-confidence"
                disabled={@curation["low_confidence_candidates"] == []}
                class={[
                  "mt-4 rounded-md border px-2 py-1 text-xs font-medium transition",
                  @curation["low_confidence_candidates"] == [] &&
                    "cursor-not-allowed border-zinc-100 text-zinc-300",
                  @curation["low_confidence_candidates"] != [] &&
                    "border-zinc-200 text-zinc-700 hover:border-zinc-400"
                ]}
              >
                Archive Low Confidence
              </button>
            </div>
            <div class="rounded-lg border border-zinc-200 bg-white p-4">
              <p class="text-sm font-semibold text-zinc-950">Duplicate Titles</p>
              <p class="mt-2 text-sm text-zinc-600">
                {length(@curation["duplicate_title_groups"])} duplicate groups
              </p>
              <div
                :if={@curation["duplicate_title_groups"] != []}
                id="memory-duplicate-title-groups"
                class="mt-3 space-y-2"
              >
                <div
                  :for={group <- Enum.take(@curation["duplicate_title_groups"], 4)}
                  id={"memory-duplicate-title-group-#{group["canonical_node"]["id"]}"}
                  class="rounded-md border border-zinc-100 bg-zinc-50 p-2 text-xs text-zinc-600"
                >
                  <p class="font-medium text-zinc-800">{group["title"]}</p>
                  <p class="mt-1">
                    keep {group["canonical_node"]["title"]} / archive {length(
                      group["duplicate_nodes"]
                    )} duplicates
                  </p>
                </div>
              </div>
              <button
                id="memory-archive-duplicate-memories"
                type="button"
                phx-click="archive-duplicate-memories"
                disabled={@curation["duplicate_title_groups"] == []}
                class={[
                  "mt-4 rounded-md border px-2 py-1 text-xs font-medium transition",
                  @curation["duplicate_title_groups"] == [] &&
                    "cursor-not-allowed border-zinc-100 text-zinc-300",
                  @curation["duplicate_title_groups"] != [] &&
                    "border-zinc-200 text-zinc-700 hover:border-zinc-400"
                ]}
              >
                Archive Duplicates
              </button>
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
