defmodule HydraAgentWeb.LoopLive do
  use HydraAgentWeb, :live_view

  alias HydraAgent.{Loops, Runtime}
  alias HydraAgent.Loops.Loop
  alias HydraAgent.Loops.Engine
  alias HydraAgentWeb.ControlShell

  @statuses ["all" | Loop.statuses()]

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Loops")
     |> assign(:workspace_id, nil)
     |> assign(:status, "all")
     |> assign(:statuses, @statuses)
     |> assign(:loop, nil)
     |> assign(:form_attrs, empty_form_attrs())
     |> assign(:form_errors, %{})
     |> assign(:recipes, Loops.recipes())
     |> load_workspaces()}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    workspace_id = selected_workspace_id(socket.assigns.workspaces, params["workspace_id"])
    status = status_param(params["status"])

    {:noreply,
     socket
     |> assign(:workspace_id, workspace_id)
     |> assign(:status, status)
     |> load_workspace_state(params)}
  end

  @impl true
  def handle_event("filter-loops", %{"status" => status}, socket) do
    {:noreply,
     push_patch(socket,
       to:
         ~p"/control/loops?workspace_id=#{socket.assigns.workspace_id}&status=#{status_param(status)}"
     )}
  end

  def handle_event("save-loop", %{"loop" => attrs}, socket) do
    attrs =
      attrs
      |> normalize_form_attrs()
      |> Map.put("workspace_id", socket.assigns.workspace_id)

    case Loops.create_loop(attrs) do
      {:ok, _loop} ->
        {:noreply,
         socket
         |> put_flash(:info, "Loop created")
         |> assign(:form_attrs, empty_form_attrs())
         |> assign(:form_errors, %{})
         |> load_workspace_state(%{})}

      {:error, changeset} ->
        {:noreply,
         socket |> assign(:form_attrs, attrs) |> assign(:form_errors, errors(changeset))}
    end
  end

  def handle_event("create-from-recipe", %{"recipe" => params}, socket) do
    params = stringify_keys(params)

    result =
      Loops.create_from_recipe(socket.assigns.workspace_id, params["recipe_id"], %{
        "supervisor_agent_id" => params["supervisor_agent_id"],
        "verifier_agent_id" => params["verifier_agent_id"],
        "status" => params["status"] || "draft"
      })

    case result do
      {:ok, _loop} ->
        {:noreply, socket |> put_flash(:info, "Loop recipe created") |> load_workspace_state(%{})}

      {:error, error} ->
        {:noreply, put_flash(socket, :error, "Loop recipe failed: #{inspect(error)}")}
    end
  end

  def handle_event("trigger-loop", %{"id" => id}, socket) do
    id
    |> loop()
    |> Engine.tick(lease_owner: "control-loop-trigger")
    |> case do
      {:ok, result} ->
        {:noreply,
         socket
         |> put_flash(:info, "Loop tick completed: #{result.stop_reason}")
         |> load_workspace_state(%{"id" => result.loop.id})}

      {:error, error} ->
        {:noreply,
         socket
         |> put_flash(:error, "Loop tick failed: #{inspect(error)}")
         |> load_workspace_state(%{"id" => id})}
    end
  end

  def handle_event("pause-loop", %{"id" => id}, socket) do
    id
    |> loop()
    |> Loops.pause_loop()
    |> handle_loop_result(socket, "Loop paused")
  end

  def handle_event("resume-loop", %{"id" => id}, socket) do
    id
    |> loop()
    |> Loops.resume_loop()
    |> handle_loop_result(socket, "Loop resumed")
  end

  def handle_event("archive-loop", %{"id" => id}, socket) do
    id
    |> loop()
    |> Loops.archive_loop()
    |> handle_loop_result(socket, "Loop archived")
  end

  defp load_workspaces(socket), do: assign(socket, :workspaces, Runtime.list_workspaces())

  defp load_workspace_state(%{assigns: %{workspace_id: nil}} = socket, _params) do
    socket
    |> assign(:loops, [])
    |> assign(:agents, [])
    |> assign(:missions, [])
    |> assign(:runs_by_loop, %{})
    |> assign(:loop, nil)
  end

  defp load_workspace_state(
         %{assigns: %{workspace_id: workspace_id, status: status}} = socket,
         params
       ) do
    loops = Loops.list_loops(workspace_id, status: status)
    selected = selected_loop(params["id"], loops)
    agents = Runtime.list_agents(workspace_id)
    missions = Runtime.list_missions(workspace_id, status: "all")

    socket
    |> assign(:loops, loops)
    |> assign(:agents, agents)
    |> assign(:missions, missions)
    |> assign(:runs_by_loop, runs_by_loop(workspace_id, loops))
    |> assign(:loop, selected)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <section id="loop-studio" class="space-y-8">
      <ControlShell.header
        active={:loops}
        description="Design durable operating programs that trigger, decide, delegate, verify, and stop under policy."
        eyebrow="Governed loops"
        query={%{status: @status}}
        title="Loops"
        workspace_id={@workspace_id}
        workspaces={@workspaces}
      />

      <%= if @workspace_id do %>
        <div class="grid gap-6 xl:grid-cols-[24rem_1fr]">
          <aside class="space-y-4">
            <form phx-submit="filter-loops" class="hx-material rounded-[var(--radius-5)] p-4">
              <label class="text-xs font-semibold uppercase tracking-[0.12em] text-zinc-500">
                Status
              </label>
              <select
                name="status"
                class="mt-2 w-full rounded-md border border-zinc-200 px-3 py-2 text-sm"
              >
                <option :for={status <- @statuses} selected={status == @status} value={status}>
                  {status}
                </option>
              </select>
              <.button class="mt-3 w-full">Filter</.button>
            </form>

            <div class="hx-material rounded-[var(--radius-5)] p-4">
              <div class="flex items-center justify-between">
                <h2 class="text-sm font-semibold text-zinc-950">Loops</h2>
                <span class="text-xs text-zinc-500">{length(@loops)} shown</span>
              </div>
              <div class="mt-3 space-y-2">
                <.link
                  :for={loop <- @loops}
                  id={"loop-row-#{loop.id}"}
                  patch={
                    ~p"/control/loops/#{loop.id}?workspace_id=#{@workspace_id}&status=#{@status}"
                  }
                  class={[
                    "block rounded-[var(--radius-3)] border p-3 text-sm transition",
                    @loop && @loop.id == loop.id && "border-zinc-950 bg-zinc-950 text-white",
                    (!@loop || @loop.id != loop.id) &&
                      "border-zinc-200 bg-white hover:border-zinc-400"
                  ]}
                >
                  <div class="flex items-center justify-between gap-3">
                    <span class="min-w-0 truncate font-semibold">{loop.name}</span>
                    <span class="text-xs opacity-75">{loop.status}</span>
                  </div>
                  <p class="mt-1 line-clamp-2 text-xs opacity-75">{loop.purpose}</p>
                </.link>
                <p :if={@loops == []} class="text-sm text-zinc-500">No loops match this filter.</p>
              </div>
            </div>

            <form phx-submit="save-loop" class="hx-material rounded-[var(--radius-5)] p-4">
              <h2 class="text-sm font-semibold text-zinc-950">Create loop</h2>
              <div class="mt-3 space-y-3">
                <.input name="loop[name]" value={@form_attrs["name"]} label="Name" required />
                <.input
                  name="loop[purpose]"
                  value={@form_attrs["purpose"]}
                  label="Purpose"
                  type="textarea"
                  required
                />
                <label class="block text-sm">
                  Supervisor
                  <select
                    name="loop[supervisor_agent_id]"
                    class="mt-1 w-full rounded-md border border-zinc-200 px-3 py-2 text-sm"
                  >
                    <option value="">None</option>
                    <option :for={agent <- @agents} value={agent.id}>{agent.name}</option>
                  </select>
                </label>
                <label class="block text-sm">
                  Verifier
                  <select
                    name="loop[verifier_agent_id]"
                    class="mt-1 w-full rounded-md border border-zinc-200 px-3 py-2 text-sm"
                  >
                    <option value="">None</option>
                    <option :for={agent <- @agents} value={agent.id}>{agent.name}</option>
                  </select>
                </label>
                <label class="block text-sm">
                  Status
                  <select
                    name="loop[status]"
                    class="mt-1 w-full rounded-md border border-zinc-200 px-3 py-2 text-sm"
                  >
                    <option value="draft">draft</option>
                    <option value="active">active</option>
                  </select>
                </label>
                <label class="block text-sm">
                  Trigger JSON <textarea
                    name="loop[trigger_json]"
                    class="mt-1 min-h-24 w-full rounded-md border border-zinc-200 px-3 py-2 font-mono text-xs"
                  ><%= json_text(@form_attrs["trigger"] || %{"type" => "manual"}) %></textarea>
                </label>
                <label class="block text-sm">
                  Body JSON <textarea
                    name="loop[body_json]"
                    class="mt-1 min-h-24 w-full rounded-md border border-zinc-200 px-3 py-2 font-mono text-xs"
                  ><%= json_text(@form_attrs["body"] || %{}) %></textarea>
                </label>
                <label class="block text-sm">
                  Guardrails JSON <textarea
                    name="loop[guardrails_json]"
                    class="mt-1 min-h-24 w-full rounded-md border border-zinc-200 px-3 py-2 font-mono text-xs"
                  ><%= json_text(@form_attrs["guardrails"] || Loop.default_guardrails()) %></textarea>
                </label>
                <p :if={@form_errors != %{}} class="rounded-md bg-red-50 p-3 text-xs text-red-700">
                  {inspect(@form_errors)}
                </p>
                <.button class="w-full">Create loop</.button>
              </div>
            </form>
          </aside>

          <main class="space-y-6">
            <%= if @loop do %>
              <.loop_detail
                loop={@loop}
                workspace_id={@workspace_id}
                runs={Map.get(@runs_by_loop, @loop.id, [])}
              />
            <% else %>
              <section class="hx-material rounded-[var(--radius-5)] p-6">
                <h2 class="text-lg font-semibold text-zinc-950">Create from recipe</h2>
                <div class="mt-4 grid gap-3 lg:grid-cols-2">
                  <form
                    :for={recipe <- @recipes}
                    id={"loop-recipe-#{recipe["id"]}"}
                    phx-submit="create-from-recipe"
                    class="rounded-[var(--radius-4)] border border-zinc-200 bg-white p-4"
                  >
                    <input type="hidden" name="recipe[recipe_id]" value={recipe["id"]} />
                    <h3 class="text-sm font-semibold text-zinc-950">{recipe["name"]}</h3>
                    <p class="mt-2 min-h-12 text-xs leading-5 text-zinc-600">{recipe["purpose"]}</p>
                    <label class="mt-3 block text-xs">
                      Supervisor
                      <select
                        name="recipe[supervisor_agent_id]"
                        class="mt-1 w-full rounded-md border border-zinc-200 px-3 py-2"
                      >
                        <option value="">None</option>
                        <option :for={agent <- @agents} value={agent.id}>{agent.name}</option>
                      </select>
                    </label>
                    <label class="mt-2 block text-xs">
                      Verifier
                      <select
                        name="recipe[verifier_agent_id]"
                        class="mt-1 w-full rounded-md border border-zinc-200 px-3 py-2"
                      >
                        <option value="">None</option>
                        <option :for={agent <- @agents} value={agent.id}>{agent.name}</option>
                      </select>
                    </label>
                    <.button class="mt-3 w-full">Install recipe</.button>
                  </form>
                </div>
              </section>
            <% end %>
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

  attr :loop, :any, required: true
  attr :runs, :list, default: []
  attr :workspace_id, :any, required: true

  def loop_detail(assigns) do
    ~H"""
    <section id={"loop-detail-#{@loop.id}"} class="hx-material rounded-[var(--radius-5)] p-6">
      <div class="flex flex-col gap-4 lg:flex-row lg:items-start lg:justify-between">
        <div>
          <p class="text-xs font-semibold uppercase tracking-[0.12em] text-[var(--accent)]">
            {@loop.status} / {@loop.autonomy_level}
          </p>
          <h2 class="mt-2 text-2xl font-semibold text-zinc-950">{@loop.name}</h2>
          <p class="mt-2 max-w-3xl text-sm leading-6 text-zinc-600">{@loop.purpose}</p>
        </div>
        <div class="flex flex-wrap gap-2">
          <.button phx-click="trigger-loop" phx-value-id={@loop.id}>Trigger</.button>
          <.button phx-click="pause-loop" phx-value-id={@loop.id}>Pause</.button>
          <.button phx-click="resume-loop" phx-value-id={@loop.id}>Resume</.button>
          <.button phx-click="archive-loop" phx-value-id={@loop.id}>Archive</.button>
        </div>
      </div>

      <div class="mt-6 grid gap-4 lg:grid-cols-3">
        <.kv title="Next tick" value={date_text(@loop.next_tick_at)} />
        <.kv title="Last tick" value={date_text(@loop.last_tick_at)} />
        <.kv title="Lease" value={lease_text(@loop)} />
      </div>

      <div class="mt-6 grid gap-4 lg:grid-cols-2">
        <.json_panel title="Trigger" value={@loop.trigger} />
        <.json_panel title="Guardrails" value={@loop.guardrails} />
        <.json_panel title="Body" value={@loop.body} />
        <.json_panel title="Durable state" value={@loop.state} />
        <.json_panel title="Budget" value={@loop.budget} />
        <.json_panel title="Last error / stop" value={@loop.last_error} />
      </div>

      <div class="mt-6">
        <h3 class="text-sm font-semibold text-zinc-950">Recent loop runs</h3>
        <div class="mt-3 grid gap-2">
          <.link
            :for={run <- @runs}
            navigate={~p"/control/runs/#{run.id}?workspace_id=#{@workspace_id}"}
            class="rounded-[var(--radius-3)] border border-zinc-200 bg-white p-3 text-sm hover:border-zinc-400"
          >
            <div class="flex items-center justify-between gap-3">
              <span class="font-semibold text-zinc-950">{run.title}</span>
              <span class="text-xs text-zinc-500">{run.status} / {run.lineage_type}</span>
            </div>
            <p class="mt-1 text-xs text-zinc-500">
              {get_in(run.metadata || %{}, ["loop_stop_reason"]) || run.goal}
            </p>
          </.link>
          <p :if={@runs == []} class="text-sm text-zinc-500">
            No runs have been linked to this loop.
          </p>
        </div>
      </div>
    </section>
    """
  end

  attr :title, :string, required: true
  attr :value, :string, required: true

  defp kv(assigns) do
    ~H"""
    <div class="rounded-[var(--radius-3)] border border-zinc-200 bg-white p-3">
      <p class="text-xs font-semibold uppercase tracking-[0.12em] text-zinc-500">{@title}</p>
      <p class="mt-2 text-sm text-zinc-950">{@value}</p>
    </div>
    """
  end

  attr :title, :string, required: true
  attr :value, :map, default: %{}

  defp json_panel(assigns) do
    ~H"""
    <div class="rounded-[var(--radius-3)] border border-zinc-200 bg-white p-4">
      <h3 class="text-sm font-semibold text-zinc-950">{@title}</h3>
      <pre class="mt-3 max-h-64 overflow-auto rounded-md bg-zinc-950 p-3 text-xs leading-5 text-zinc-50"><%= json_text(@value) %></pre>
    </div>
    """
  end

  defp handle_loop_result(result, socket, message) do
    case result do
      {:ok, loop} ->
        {:noreply,
         socket |> put_flash(:info, message) |> load_workspace_state(%{"id" => loop.id})}

      {:error, error} ->
        {:noreply, put_flash(socket, :error, "Loop update failed: #{inspect(error)}")}
    end
  end

  defp runs_by_loop(workspace_id, loops) do
    workspace_id
    |> Runtime.list_runs(limit: 300)
    |> Enum.filter(& &1.loop_id)
    |> Enum.group_by(& &1.loop_id)
    |> Map.take(Enum.map(loops, & &1.id))
  end

  defp selected_loop(nil, _loops), do: nil

  defp selected_loop(id, loops) do
    parsed_id = parse_int(id)

    if Enum.any?(loops, &(&1.id == parsed_id)) do
      Loops.get_loop!(parsed_id)
    end
  end

  defp loop(id), do: Loops.get_loop!(id)

  defp normalize_form_attrs(attrs) do
    attrs = stringify_keys(attrs)

    attrs
    |> Map.put("trigger", decode_json(attrs["trigger_json"], %{"type" => "manual"}))
    |> Map.put("body", decode_json(attrs["body_json"], %{}))
    |> Map.put("guardrails", decode_json(attrs["guardrails_json"], Loop.default_guardrails()))
    |> Map.drop(~w(trigger_json body_json guardrails_json))
    |> drop_blank_ids()
  end

  defp drop_blank_ids(attrs) do
    attrs
    |> maybe_drop_blank("supervisor_agent_id")
    |> maybe_drop_blank("verifier_agent_id")
    |> maybe_drop_blank("mission_id")
  end

  defp maybe_drop_blank(attrs, key) do
    if attrs[key] in [nil, ""], do: Map.delete(attrs, key), else: attrs
  end

  defp decode_json(nil, default), do: default
  defp decode_json("", default), do: default

  defp decode_json(text, default) do
    case Jason.decode(text) do
      {:ok, value} when is_map(value) -> value
      _error -> default
    end
  end

  defp empty_form_attrs do
    %{
      "name" => "",
      "purpose" => "",
      "status" => "draft",
      "trigger" => %{"type" => "manual"},
      "body" => %{},
      "guardrails" => Loop.default_guardrails()
    }
  end

  defp selected_workspace_id([], _param), do: nil
  defp selected_workspace_id(workspaces, nil), do: workspaces |> List.first() |> Map.get(:id)

  defp selected_workspace_id(workspaces, workspace_id) do
    parsed_id = parse_int(workspace_id)

    if Enum.any?(workspaces, &(&1.id == parsed_id)),
      do: parsed_id,
      else: selected_workspace_id(workspaces, nil)
  end

  defp status_param(status) when status in @statuses, do: status
  defp status_param(_status), do: "all"

  defp parse_int(value) when is_integer(value), do: value
  defp parse_int(value) when is_binary(value), do: String.to_integer(value)

  defp json_text(nil), do: "{}"
  defp json_text(map) when is_map(map), do: Jason.encode!(map, pretty: true)
  defp json_text(value), do: inspect(value)

  defp date_text(nil), do: "not scheduled"
  defp date_text(%DateTime{} = datetime), do: DateTime.to_iso8601(datetime)

  defp lease_text(%Loop{lease_owner: nil}), do: "free"

  defp lease_text(%Loop{} = loop),
    do: "#{loop.lease_owner} until #{date_text(loop.lease_expires_at)}"

  defp errors(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
      Enum.reduce(opts, message, fn {key, value}, acc ->
        String.replace(acc, "%{#{key}}", to_string(value))
      end)
    end)
  end

  defp stringify_keys(map) when is_map(map),
    do: Map.new(map, fn {key, value} -> {to_string(key), value} end)
end
