defmodule HydraAgentWeb.SimulationLive do
  use HydraAgentWeb, :live_view

  alias HydraAgent.Runtime
  alias HydraAgent.Runtime.PubSub
  alias HydraAgent.Simulation
  alias HydraAgentWeb.ControlShell

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Simulations")
     |> assign(:workspace_id, nil)
     |> assign(:selected_simulation, nil)
     |> assign(:worker_status, nil)
     |> assign(:subscribed_simulation_id, nil)
     |> assign(:simulation_form, simulation_form_defaults())
     |> assign(
       :simulation_estimate,
       Simulation.estimate(%{"config" => form_config(simulation_form_defaults())})
     )
     |> load_workspaces()}
  end

  @impl true
  def handle_params(%{"id" => id} = params, _uri, socket) do
    workspace_id = selected_workspace_id(socket.assigns.workspaces, params["workspace_id"])
    simulation = Simulation.get_simulation_for_workspace!(workspace_id, id)

    socket =
      socket
      |> assign(:workspace_id, workspace_id)
      |> maybe_subscribe(simulation.id)
      |> assign(:selected_simulation, simulation)
      |> assign(:worker_status, Simulation.worker_status(simulation))
      |> load_workspace_state()

    {:noreply, socket}
  end

  def handle_params(params, _uri, socket) do
    workspace_id = selected_workspace_id(socket.assigns.workspaces, params["workspace_id"])

    socket =
      socket
      |> assign(:workspace_id, workspace_id)
      |> assign(:selected_simulation, nil)
      |> assign(:worker_status, nil)
      |> load_workspace_state()

    {:noreply, socket}
  end

  @impl true
  def handle_info({:simulation_updated, simulation}, socket) do
    socket =
      if socket.assigns.selected_simulation &&
           socket.assigns.selected_simulation.id == simulation.id do
        selected = Simulation.get_simulation!(simulation.id)

        socket
        |> assign(:selected_simulation, selected)
        |> assign(:worker_status, Simulation.worker_status(selected))
      else
        socket
      end

    {:noreply, load_workspace_state(socket)}
  end

  def handle_info({:simulation_tick, simulation, _tick}, socket) do
    socket =
      if socket.assigns.selected_simulation &&
           socket.assigns.selected_simulation.id == simulation.id do
        selected = Simulation.get_simulation!(simulation.id)

        socket
        |> assign(:selected_simulation, selected)
        |> assign(:worker_status, Simulation.worker_status(selected))
      else
        socket
      end

    {:noreply, load_workspace_state(socket)}
  end

  @impl true
  def handle_event("start", %{"id" => id}, socket) do
    socket =
      id
      |> get_simulation(socket)
      |> Simulation.start_simulation()
      |> handle_result(socket, "Simulation started")

    {:noreply, reload_selected(socket)}
  end

  def handle_event("pause", %{"id" => id}, socket) do
    socket =
      id
      |> get_simulation(socket)
      |> Simulation.pause_simulation()
      |> handle_result(socket, "Simulation paused")

    {:noreply, reload_selected(socket)}
  end

  def handle_event("resume", %{"id" => id}, socket) do
    socket =
      id
      |> get_simulation(socket)
      |> Simulation.resume_simulation()
      |> handle_result(socket, "Simulation resumed")

    {:noreply, reload_selected(socket)}
  end

  def handle_event("cancel", %{"id" => id}, socket) do
    socket =
      id
      |> get_simulation(socket)
      |> Simulation.cancel_simulation()
      |> handle_result(socket, "Simulation canceled")

    {:noreply, reload_selected(socket)}
  end

  def handle_event("report", %{"id" => id}, socket) do
    socket =
      id
      |> get_simulation(socket)
      |> Simulation.generate_report()
      |> handle_result(socket, "Report generated")

    {:noreply, reload_selected(socket)}
  end

  def handle_event("duplicate", %{"id" => id}, socket) do
    result =
      id
      |> get_simulation(socket)
      |> Simulation.duplicate_simulation()

    case result do
      {:ok, simulation} ->
        {:noreply,
         socket
         |> put_flash(:info, "Simulation duplicated")
         |> push_patch(
           to:
             ~p"/control/simulations/#{simulation.id}?workspace_id=#{socket.assigns.workspace_id}"
         )}

      {:error, error} ->
        {:noreply, put_flash(socket, :error, inspect(error))}
    end
  end

  def handle_event("estimate", %{"simulation" => attrs}, socket) do
    attrs = normalize_form_attrs(attrs)

    {:noreply,
     socket
     |> assign(:simulation_form, attrs)
     |> assign(:simulation_estimate, Simulation.estimate(%{"config" => form_config(attrs)}))}
  end

  def handle_event("create", %{"simulation" => attrs}, socket) do
    attrs = normalize_form_attrs(attrs)

    result =
      Simulation.create_simulation(%{
        workspace_id: socket.assigns.workspace_id,
        title: attrs["title"],
        goal: attrs["goal"],
        config: form_config(attrs)
      })

    case result do
      {:ok, simulation} ->
        {:noreply,
         socket
         |> put_flash(:info, "Simulation created")
         |> assign(:simulation_form, simulation_form_defaults())
         |> assign(
           :simulation_estimate,
           Simulation.estimate(%{"config" => form_config(simulation_form_defaults())})
         )
         |> push_patch(
           to:
             ~p"/control/simulations/#{simulation.id}?workspace_id=#{socket.assigns.workspace_id}"
         )}

      {:error, error} ->
        {:noreply,
         socket
         |> assign(:simulation_form, attrs)
         |> assign(:simulation_estimate, Simulation.estimate(%{"config" => form_config(attrs)}))
         |> put_flash(:error, inspect(error))}
    end
  end

  defp load_workspaces(socket), do: assign(socket, :workspaces, Runtime.list_workspaces())

  defp load_workspace_state(%{assigns: %{workspace_id: nil}} = socket) do
    assign(socket, :simulations, [])
  end

  defp load_workspace_state(%{assigns: %{workspace_id: workspace_id}} = socket) do
    assign(socket, :simulations, Simulation.list_simulations(workspace_id))
  end

  defp maybe_subscribe(socket, simulation_id) do
    if connected?(socket) && socket.assigns.subscribed_simulation_id != simulation_id do
      PubSub.subscribe_simulation(simulation_id)
    end

    assign(socket, :subscribed_simulation_id, simulation_id)
  end

  defp reload_selected(%{assigns: %{selected_simulation: nil}} = socket),
    do: load_workspace_state(socket)

  defp reload_selected(%{assigns: %{selected_simulation: simulation}} = socket) do
    selected = Simulation.get_simulation!(simulation.id)

    socket
    |> assign(:selected_simulation, selected)
    |> assign(:worker_status, Simulation.worker_status(selected))
    |> load_workspace_state()
  end

  defp get_simulation(id, socket) do
    Simulation.get_simulation_for_workspace!(socket.assigns.workspace_id, id)
  end

  defp handle_result({:ok, _result}, socket, message), do: put_flash(socket, :info, message)

  defp handle_result({:error, error}, socket, _message),
    do: put_flash(socket, :error, inspect(error))

  defp selected_workspace_id([], _param), do: nil
  defp selected_workspace_id([workspace | _workspaces], nil), do: workspace.id

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

  defp cents(cents), do: "$#{:erlang.float_to_binary((cents || 0) / 100, decimals: 2)}"

  defp timestamp(nil), do: "n/a"
  defp timestamp(datetime), do: Calendar.strftime(datetime, "%m-%d %H:%M:%S")

  defp simulation_form_defaults do
    %{
      "title" => "",
      "goal" => "",
      "agent_count" => "20",
      "max_ticks" => "40",
      "max_budget_cents" => "50",
      "event_frequency" => "0.3",
      "scenario_template" => "product_rollout",
      "rng_seed" => "1",
      "max_tick_cost_cents" => "",
      "max_agent_cost_cents" => "",
      "max_llm_calls" => "",
      "max_wall_clock_seconds" => "",
      "cheap_provider" => "",
      "frontier_provider" => ""
    }
  end

  defp normalize_form_attrs(attrs) do
    Map.merge(simulation_form_defaults(), attrs || %{})
  end

  defp form_config(attrs) do
    %{
      "agent_count" => attrs["agent_count"],
      "max_ticks" => attrs["max_ticks"],
      "max_budget_cents" => attrs["max_budget_cents"],
      "event_frequency" => attrs["event_frequency"],
      "scenario_template" => attrs["scenario_template"],
      "rng_seed" => attrs["rng_seed"],
      "max_tick_cost_cents" => blank_to_nil(attrs["max_tick_cost_cents"]),
      "max_agent_cost_cents" => blank_to_nil(attrs["max_agent_cost_cents"]),
      "max_llm_calls" => blank_to_nil(attrs["max_llm_calls"]),
      "max_wall_clock_seconds" => blank_to_nil(attrs["max_wall_clock_seconds"]),
      "cheap_provider" => blank_to_nil(attrs["cheap_provider"]),
      "frontier_provider" => blank_to_nil(attrs["frontier_provider"])
    }
  end

  defp blank_to_nil(value) when value in [nil, ""], do: nil
  defp blank_to_nil(value), do: value

  @impl true
  def render(assigns) do
    ~H"""
    <section id="simulations" class="space-y-8">
      <ControlShell.header
        active={:simulations}
        description="Run neutral, budget-capped simulated worlds with deterministic routing and selective LLM escalation."
        eyebrow="Runtime"
        title="Simulations"
        workspaces={@workspaces}
        workspace_id={@workspace_id}
      />

      <%= if @workspace_id do %>
        <form
          id="simulation-create-form"
          phx-change="estimate"
          phx-submit="create"
          class="grid gap-4 rounded-lg border border-zinc-200 bg-white p-4 lg:grid-cols-[1.4fr_1.6fr]"
        >
          <div class="space-y-3">
            <div>
              <label class="text-xs font-semibold text-zinc-600" for="simulation-title">
                Title
              </label>
              <input
                id="simulation-title"
                name="simulation[title]"
                value={@simulation_form["title"]}
                required
                class="mt-1 w-full rounded-md border border-zinc-200 px-3 py-2 text-sm"
              />
            </div>
            <div>
              <label class="text-xs font-semibold text-zinc-600" for="simulation-goal">
                Goal
              </label>
              <textarea
                id="simulation-goal"
                name="simulation[goal]"
                required
                rows="4"
                class="mt-1 w-full rounded-md border border-zinc-200 px-3 py-2 text-sm"
              >{@simulation_form["goal"]}</textarea>
            </div>
          </div>

          <div class="grid gap-3 md:grid-cols-2">
            <div>
              <label class="text-xs font-semibold text-zinc-600" for="simulation-agent-count">
                Agents
              </label>
              <input
                id="simulation-agent-count"
                name="simulation[agent_count]"
                type="number"
                min="1"
                value={@simulation_form["agent_count"]}
                class="mt-1 w-full rounded-md border border-zinc-200 px-3 py-2 text-sm"
              />
            </div>
            <div>
              <label class="text-xs font-semibold text-zinc-600" for="simulation-max-ticks">
                Max ticks
              </label>
              <input
                id="simulation-max-ticks"
                name="simulation[max_ticks]"
                type="number"
                min="1"
                value={@simulation_form["max_ticks"]}
                class="mt-1 w-full rounded-md border border-zinc-200 px-3 py-2 text-sm"
              />
            </div>
            <div>
              <label class="text-xs font-semibold text-zinc-600" for="simulation-budget">
                Budget cents
              </label>
              <input
                id="simulation-budget"
                name="simulation[max_budget_cents]"
                type="number"
                min="1"
                value={@simulation_form["max_budget_cents"]}
                class="mt-1 w-full rounded-md border border-zinc-200 px-3 py-2 text-sm"
              />
            </div>
            <div>
              <label class="text-xs font-semibold text-zinc-600" for="simulation-frequency">
                Event frequency
              </label>
              <input
                id="simulation-frequency"
                name="simulation[event_frequency]"
                type="number"
                min="0"
                max="1"
                step="0.05"
                value={@simulation_form["event_frequency"]}
                class="mt-1 w-full rounded-md border border-zinc-200 px-3 py-2 text-sm"
              />
            </div>
            <div>
              <label class="text-xs font-semibold text-zinc-600" for="simulation-scenario">
                Scenario
              </label>
              <select
                id="simulation-scenario"
                name="simulation[scenario_template]"
                class="mt-1 w-full rounded-md border border-zinc-200 px-3 py-2 text-sm"
              >
                <option
                  value="product_rollout"
                  selected={@simulation_form["scenario_template"] == "product_rollout"}
                >
                  Product rollout
                </option>
                <option
                  value="incident_response"
                  selected={@simulation_form["scenario_template"] == "incident_response"}
                >
                  Incident response
                </option>
                <option
                  value="market_shock"
                  selected={@simulation_form["scenario_template"] == "market_shock"}
                >
                  Market shock
                </option>
                <option
                  value="negotiation"
                  selected={@simulation_form["scenario_template"] == "negotiation"}
                >
                  Negotiation
                </option>
                <option
                  value="support_surge"
                  selected={@simulation_form["scenario_template"] == "support_surge"}
                >
                  Support surge
                </option>
              </select>
            </div>
            <div>
              <label class="text-xs font-semibold text-zinc-600" for="simulation-seed">
                Seed
              </label>
              <input
                id="simulation-seed"
                name="simulation[rng_seed]"
                type="number"
                min="1"
                value={@simulation_form["rng_seed"]}
                class="mt-1 w-full rounded-md border border-zinc-200 px-3 py-2 text-sm"
              />
            </div>
            <div>
              <label class="text-xs font-semibold text-zinc-600" for="simulation-tick-cap">
                Tick cap cents
              </label>
              <input
                id="simulation-tick-cap"
                name="simulation[max_tick_cost_cents]"
                type="number"
                min="1"
                value={@simulation_form["max_tick_cost_cents"]}
                class="mt-1 w-full rounded-md border border-zinc-200 px-3 py-2 text-sm"
              />
            </div>
            <div>
              <label class="text-xs font-semibold text-zinc-600" for="simulation-agent-cap">
                Agent cap cents
              </label>
              <input
                id="simulation-agent-cap"
                name="simulation[max_agent_cost_cents]"
                type="number"
                min="1"
                value={@simulation_form["max_agent_cost_cents"]}
                class="mt-1 w-full rounded-md border border-zinc-200 px-3 py-2 text-sm"
              />
            </div>
            <div>
              <label class="text-xs font-semibold text-zinc-600" for="simulation-call-cap">
                LLM call cap
              </label>
              <input
                id="simulation-call-cap"
                name="simulation[max_llm_calls]"
                type="number"
                min="1"
                value={@simulation_form["max_llm_calls"]}
                class="mt-1 w-full rounded-md border border-zinc-200 px-3 py-2 text-sm"
              />
            </div>
            <div>
              <label class="text-xs font-semibold text-zinc-600" for="simulation-wall-clock">
                Wall-clock seconds
              </label>
              <input
                id="simulation-wall-clock"
                name="simulation[max_wall_clock_seconds]"
                type="number"
                min="1"
                value={@simulation_form["max_wall_clock_seconds"]}
                class="mt-1 w-full rounded-md border border-zinc-200 px-3 py-2 text-sm"
              />
            </div>
            <div>
              <label class="text-xs font-semibold text-zinc-600" for="simulation-cheap-provider">
                Cheap provider
              </label>
              <input
                id="simulation-cheap-provider"
                name="simulation[cheap_provider]"
                value={@simulation_form["cheap_provider"]}
                class="mt-1 w-full rounded-md border border-zinc-200 px-3 py-2 text-sm"
              />
            </div>
            <div>
              <label class="text-xs font-semibold text-zinc-600" for="simulation-frontier-provider">
                Frontier provider
              </label>
              <input
                id="simulation-frontier-provider"
                name="simulation[frontier_provider]"
                value={@simulation_form["frontier_provider"]}
                class="mt-1 w-full rounded-md border border-zinc-200 px-3 py-2 text-sm"
              />
            </div>
            <div class="flex flex-wrap items-center gap-3 text-xs text-zinc-500 md:col-span-2">
              <span>{@simulation_estimate["estimated_decisions"]} decisions</span>
              <span>{@simulation_estimate["estimated_complex_calls"]} cheap calls</span>
              <span>{@simulation_estimate["estimated_negotiation_calls"]} frontier calls</span>
              <span>{cents(@simulation_estimate["estimated_cost_cents"])}</span>
              <button
                type="submit"
                class="ml-auto rounded-md bg-zinc-950 px-3 py-2 text-xs font-medium text-white"
              >
                Create
              </button>
            </div>
          </div>
        </form>

        <div class="grid gap-6 xl:grid-cols-[0.85fr_1.15fr]">
          <section class="space-y-3">
            <h2 class="text-lg font-semibold text-zinc-950">Simulation Runs</h2>
            <div class="overflow-hidden rounded-lg border border-zinc-200 bg-white">
              <div
                :for={simulation <- @simulations}
                id={"simulation-row-#{simulation.id}"}
                class="border-b border-zinc-100 p-4 last:border-b-0"
              >
                <.link
                  navigate={~p"/control/simulations/#{simulation.id}?workspace_id=#{@workspace_id}"}
                  class="block"
                >
                  <div class="flex items-start justify-between gap-3">
                    <div class="min-w-0">
                      <p class="truncate text-sm font-semibold text-zinc-950">{simulation.title}</p>
                      <p class="mt-1 line-clamp-2 text-xs text-zinc-500">{simulation.goal}</p>
                    </div>
                    <span class="rounded-md bg-zinc-100 px-2 py-1 text-xs font-medium text-zinc-700">
                      {simulation.status}
                    </span>
                  </div>
                  <div class="mt-3 flex flex-wrap gap-3 text-xs text-zinc-500">
                    <span>{simulation.total_ticks} ticks</span>
                    <span>{simulation.total_llm_calls} LLM calls</span>
                    <span>{cents(simulation.total_cost_cents)}</span>
                  </div>
                </.link>
              </div>
              <div :if={@simulations == []} class="p-8 text-sm text-zinc-500">
                No simulations have been created yet.
              </div>
            </div>
          </section>

          <section class="space-y-3">
            <%= if @selected_simulation do %>
              <div class="rounded-lg border border-zinc-200 bg-white p-5">
                <div class="flex items-start justify-between gap-4">
                  <div>
                    <p class="text-xs font-semibold uppercase tracking-[0.14em] text-zinc-500">
                      {@selected_simulation.status}
                    </p>
                    <h2 class="mt-2 text-xl font-semibold text-zinc-950">
                      {@selected_simulation.title}
                    </h2>
                    <p class="mt-2 text-sm text-zinc-600">{@selected_simulation.goal}</p>
                  </div>
                  <div class="flex gap-2">
                    <button
                      :if={@selected_simulation.status in ["configuring", "paused"]}
                      phx-click={
                        if @selected_simulation.status == "paused", do: "resume", else: "start"
                      }
                      phx-value-id={@selected_simulation.id}
                      class="rounded-md bg-zinc-950 px-3 py-2 text-xs font-medium text-white"
                    >
                      {if @selected_simulation.status == "paused", do: "Resume", else: "Start"}
                    </button>
                    <button
                      :if={@selected_simulation.status == "running"}
                      phx-click="pause"
                      phx-value-id={@selected_simulation.id}
                      class="rounded-md border border-zinc-200 px-3 py-2 text-xs font-medium"
                    >
                      Pause
                    </button>
                    <button
                      :if={@selected_simulation.status in ["running", "paused", "configuring"]}
                      phx-click="cancel"
                      phx-value-id={@selected_simulation.id}
                      class="rounded-md border border-zinc-200 px-3 py-2 text-xs font-medium"
                    >
                      Cancel
                    </button>
                    <button
                      :if={@selected_simulation.status in ["completed", "budget_blocked", "failed"]}
                      phx-click="report"
                      phx-value-id={@selected_simulation.id}
                      class="rounded-md border border-zinc-200 px-3 py-2 text-xs font-medium"
                    >
                      Report
                    </button>
                    <button
                      phx-click="duplicate"
                      phx-value-id={@selected_simulation.id}
                      class="rounded-md border border-zinc-200 px-3 py-2 text-xs font-medium"
                    >
                      Duplicate
                    </button>
                  </div>
                </div>

                <div class="mt-5 h-2 overflow-hidden rounded-full bg-zinc-100">
                  <div
                    class="h-full bg-zinc-900"
                    style={"width: #{min(round((@selected_simulation.total_ticks / max(@selected_simulation.config["max_ticks"] || 1, 1)) * 100), 100)}%"}
                  />
                </div>

                <div class="mt-4 grid gap-3 md:grid-cols-3">
                  <div class="rounded-lg border border-zinc-200 p-3 text-xs">
                    <p class="font-semibold text-zinc-950">Worker</p>
                    <p class="mt-1 text-zinc-600">
                      {if @worker_status && @worker_status.active, do: "active", else: "idle"}
                    </p>
                  </div>
                  <div class="rounded-lg border border-zinc-200 p-3 text-xs">
                    <p class="font-semibold text-zinc-950">Lease</p>
                    <p class="mt-1 truncate text-zinc-600">
                      {@selected_simulation.lease_id || "none"}
                    </p>
                  </div>
                  <div class="rounded-lg border border-zinc-200 p-3 text-xs">
                    <p class="font-semibold text-zinc-950">Heartbeat</p>
                    <p class="mt-1 text-zinc-600">
                      {timestamp(@selected_simulation.last_heartbeat_at)}
                    </p>
                  </div>
                </div>

                <div class="mt-5 grid gap-3 md:grid-cols-5">
                  <div class="rounded-lg border border-zinc-200 p-3">
                    <p class="text-xs text-zinc-500">Ticks</p>
                    <p class="mt-1 text-2xl font-semibold">
                      {@selected_simulation.total_ticks}/{@selected_simulation.config["max_ticks"]}
                    </p>
                  </div>
                  <div class="rounded-lg border border-zinc-200 p-3">
                    <p class="text-xs text-zinc-500">LLM calls</p>
                    <p class="mt-1 text-2xl font-semibold">{@selected_simulation.total_llm_calls}</p>
                  </div>
                  <div class="rounded-lg border border-zinc-200 p-3">
                    <p class="text-xs text-zinc-500">Tokens</p>
                    <p class="mt-1 text-2xl font-semibold">
                      {@selected_simulation.total_tokens_used}
                    </p>
                  </div>
                  <div class="rounded-lg border border-zinc-200 p-3">
                    <p class="text-xs text-zinc-500">Cost</p>
                    <p class="mt-1 text-2xl font-semibold">
                      {cents(@selected_simulation.total_cost_cents)}
                    </p>
                  </div>
                  <div class="rounded-lg border border-zinc-200 p-3">
                    <p class="text-xs text-zinc-500">Reserved</p>
                    <p class="mt-1 text-2xl font-semibold">
                      {cents(
                        get_in(@selected_simulation.budget_usage || %{}, ["reserved_cost_cents"]) || 0
                      )}
                    </p>
                  </div>
                </div>

                <div class="mt-5 grid gap-4 md:grid-cols-2">
                  <div>
                    <h3 class="text-sm font-semibold text-zinc-950">Recent Ticks</h3>
                    <div class="mt-2 space-y-2">
                      <div
                        :for={tick <- Enum.take(Enum.reverse(@selected_simulation.ticks), 8)}
                        class="rounded-md border border-zinc-200 px-3 py-2 text-xs"
                      >
                        Tick {tick.tick_number} · {tick.llm_calls} LLM · {cents(tick.cost_cents)}
                      </div>
                    </div>
                  </div>
                  <div>
                    <h3 class="text-sm font-semibold text-zinc-950">Reports</h3>
                    <div class="mt-2 space-y-2">
                      <div
                        :for={report <- Enum.take(Enum.reverse(@selected_simulation.reports), 3)}
                        class="rounded-md border border-zinc-200 px-3 py-2 text-xs text-zinc-600"
                      >
                        {String.slice(report.content, 0, 180)}
                      </div>
                      <div :if={@selected_simulation.reports == []} class="text-sm text-zinc-500">
                        No report generated yet.
                      </div>
                    </div>
                  </div>
                </div>
              </div>
            <% else %>
              <div class="rounded-lg border border-zinc-200 bg-white p-8 text-sm text-zinc-500">
                Select a simulation to inspect its live ticks, budget, and report.
              </div>
            <% end %>
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
