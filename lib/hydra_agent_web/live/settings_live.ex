defmodule HydraAgentWeb.SettingsLive do
  use HydraAgentWeb, :live_view

  alias HydraAgent.{Budgets, Connectors, Runtime}
  alias HydraAgentWeb.ControlShell

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Settings")
     |> assign(:workspace_id, nil)
     |> assign(:budget_form, empty_budget_form())
     |> assign(:budget_errors, %{})
     |> assign(:permission_presets, Connectors.permission_presets())
     |> assign(:tool_bundles, Runtime.tool_bundles())
     |> load_workspaces()}
  end

  @impl true
  def handle_event("validate-budget", %{"budget" => attrs}, socket) do
    attrs = normalize_budget_attrs(attrs)

    {:noreply,
     socket
     |> assign(:budget_form, attrs)
     |> assign(:budget_errors, %{})}
  end

  def handle_event("create-budget", %{"budget" => attrs}, socket) do
    attrs =
      attrs
      |> normalize_budget_attrs()
      |> Map.put("workspace_id", socket.assigns.workspace_id)

    case Budgets.create_budget(attrs) do
      {:ok, _budget} ->
        {:noreply,
         socket
         |> put_flash(:info, "Budget guardrail created")
         |> assign(:budget_form, default_budget_form(socket.assigns))
         |> assign(:budget_errors, %{})
         |> load_workspace_state()}

      {:error, changeset} ->
        {:noreply,
         socket
         |> assign(:budget_form, attrs)
         |> assign(:budget_errors, changeset_errors(changeset))}
    end
  end

  @impl true
  def handle_params(params, _uri, socket) do
    workspace_id = selected_workspace_id(socket.assigns.workspaces, params["workspace_id"])

    {:noreply,
     socket
     |> assign(:workspace_id, workspace_id)
     |> load_workspace_state()}
  end

  defp load_workspaces(socket), do: assign(socket, :workspaces, Runtime.list_workspaces())

  defp load_workspace_state(%{assigns: %{workspace_id: nil}} = socket) do
    socket
    |> assign(:providers, [])
    |> assign(:credential_pools, [])
    |> assign(:tool_policies, [])
    |> assign(:budgets, [])
    |> assign(:agents, [])
    |> assign(:agents_by_id, %{})
    |> assign(:budget_summary, budget_summary([]))
  end

  defp load_workspace_state(%{assigns: %{workspace_id: workspace_id}} = socket) do
    agents = Runtime.list_agents(workspace_id)
    budget_records = Budgets.list_budgets(workspace_id)
    budget_statuses = Map.new(Budgets.list_budget_statuses(workspace_id), &{&1["budget_id"], &1})

    budgets =
      Enum.map(budget_records, fn budget ->
        %{"budget" => budget, "usage_status" => budget_statuses[budget.id]}
      end)

    socket
    |> assign(:providers, Runtime.list_providers(workspace_id))
    |> assign(:credential_pools, Runtime.list_credential_pools(workspace_id))
    |> assign(:tool_policies, Runtime.list_tool_policies(workspace_id))
    |> assign(:budgets, budgets)
    |> assign(:agents, agents)
    |> assign(:agents_by_id, Map.new(agents, &{&1.id, &1}))
    |> assign(:budget_summary, budget_summary(budgets))
    |> assign(:budget_form, default_budget_form(%{agents: agents}))
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

  defp join_or_none([]), do: "none"
  defp join_or_none(values), do: Enum.join(values, ", ")

  defp empty_budget_form do
    %{
      "agent_id" => "",
      "name" => "",
      "category" => "",
      "period" => "monthly",
      "token_limit" => ""
    }
  end

  defp default_budget_form(assigns) do
    empty_budget_form()
    |> Map.put("agent_id", "")
    |> Map.put("name", "Workspace Monthly Token Limit")
    |> maybe_default_agent(assigns)
  end

  defp maybe_default_agent(attrs, %{agents: [_agent | _agents]}), do: attrs
  defp maybe_default_agent(attrs, _assigns), do: attrs

  defp normalize_budget_attrs(attrs) do
    attrs
    |> stringify_keys()
    |> normalize_blank("agent_id")
    |> normalize_blank("category")
    |> normalize_token_limit()
  end

  defp normalize_blank(attrs, key) do
    case Map.get(attrs, key) do
      "" -> Map.put(attrs, key, nil)
      value -> Map.put(attrs, key, value)
    end
  end

  defp normalize_token_limit(attrs) do
    case Map.get(attrs, "token_limit") do
      value when is_integer(value) ->
        attrs

      value when value in [nil, ""] ->
        Map.put(attrs, "token_limit", nil)

      value ->
        case Integer.parse(to_string(value)) do
          {parsed, ""} -> Map.put(attrs, "token_limit", parsed)
          _other -> attrs
        end
    end
  end

  defp stringify_keys(map) when is_map(map),
    do: Map.new(map, fn {key, value} -> {to_string(key), value} end)

  defp budget_summary(budgets) do
    statuses = Enum.map(budgets, &get_in(&1, ["usage_status", "status"]))

    %{
      total: length(budgets),
      exceeded: Enum.count(statuses, &(&1 == "exceeded")),
      warning: Enum.count(statuses, &(&1 == "warning")),
      ok: Enum.count(statuses, &(&1 == "ok")),
      unbounded: Enum.count(statuses, &(&1 == "unbounded"))
    }
  end

  defp budget_agent_name(nil, _agents_by_id), do: "workspace"

  defp budget_agent_name(agent_id, agents_by_id) do
    case Map.get(agents_by_id, agent_id) do
      nil -> "agent #{agent_id}"
      agent -> agent.name
    end
  end

  defp budget_ratio(nil), do: "n/a"
  defp budget_ratio(ratio), do: "#{round(ratio * 100)}%"

  defp budget_error(errors, field), do: Enum.join(Map.get(errors, field, []), ", ")

  defp changeset_errors(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
      Enum.reduce(opts, message, fn {key, value}, acc ->
        String.replace(acc, "%{#{key}}", to_string(value))
      end)
    end)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <section id="settings" class="space-y-8">
      <ControlShell.header
        active={:settings}
        description="Workspace-level provider, credential, policy, and budget posture."
        eyebrow="Administration"
        title="Settings"
        workspaces={@workspaces}
        workspace_id={@workspace_id}
      />

      <%= if @workspace_id do %>
        <div class="grid gap-4 md:grid-cols-2 xl:grid-cols-4">
          <div class="rounded-lg border border-zinc-200 bg-white p-4">
            <p class="text-xs font-semibold uppercase tracking-[0.14em] text-zinc-500">Providers</p>
            <p class="mt-3 text-3xl font-semibold text-zinc-950">{length(@providers)}</p>
          </div>
          <div class="rounded-lg border border-zinc-200 bg-white p-4">
            <p class="text-xs font-semibold uppercase tracking-[0.14em] text-zinc-500">Credentials</p>
            <p class="mt-3 text-3xl font-semibold text-zinc-950">{length(@credential_pools)}</p>
          </div>
          <div class="rounded-lg border border-zinc-200 bg-white p-4">
            <p class="text-xs font-semibold uppercase tracking-[0.14em] text-zinc-500">Policies</p>
            <p class="mt-3 text-3xl font-semibold text-zinc-950">{length(@tool_policies)}</p>
          </div>
          <div class="rounded-lg border border-zinc-200 bg-white p-4">
            <p class="text-xs font-semibold uppercase tracking-[0.14em] text-zinc-500">Budgets</p>
            <p class="mt-3 text-3xl font-semibold text-zinc-950">{@budget_summary.total}</p>
            <p class="mt-1 text-sm text-zinc-600">
              {@budget_summary.warning + @budget_summary.exceeded} need attention
            </p>
          </div>
        </div>

        <section class="rounded-lg border border-zinc-200 bg-white p-5">
          <div class="flex flex-col gap-4 xl:flex-row xl:items-start xl:justify-between">
            <div>
              <h2 class="text-base font-semibold text-zinc-950">Permission Presets</h2>
              <p class="mt-1 text-sm text-zinc-500">
                Reusable trust levels for connector writes, delivery actions, and token spend.
              </p>
            </div>
            <div class="grid gap-2 text-xs text-zinc-600 sm:grid-cols-4 xl:w-[520px]">
              <div class="rounded-md border border-zinc-200 p-2">
                <p class="font-semibold text-zinc-950">OK</p>
                <p>{@budget_summary.ok}</p>
              </div>
              <div class="rounded-md border border-zinc-200 p-2">
                <p class="font-semibold text-zinc-950">Warning</p>
                <p>{@budget_summary.warning}</p>
              </div>
              <div class="rounded-md border border-zinc-200 p-2">
                <p class="font-semibold text-zinc-950">Exceeded</p>
                <p>{@budget_summary.exceeded}</p>
              </div>
              <div class="rounded-md border border-zinc-200 p-2">
                <p class="font-semibold text-zinc-950">Unbounded</p>
                <p>{@budget_summary.unbounded}</p>
              </div>
            </div>
          </div>

          <div id="settings-permission-presets" class="mt-4 grid gap-3 md:grid-cols-2 xl:grid-cols-4">
            <div
              :for={preset <- @permission_presets}
              id={"settings-permission-preset-#{preset.id}"}
              class="rounded-lg border border-zinc-200 p-4 text-sm"
            >
              <div class="flex items-start justify-between gap-3">
                <p class="font-semibold text-zinc-950">{preset.label}</p>
                <span class={[
                  "text-xs font-semibold",
                  Map.get(preset, :trusted) && "text-emerald-700",
                  !Map.get(preset, :trusted) && preset.requires_approval && "text-amber-700",
                  !preset.requires_approval && "text-zinc-500"
                ]}>
                  {cond do
                    Map.get(preset, :trusted) -> "trusted"
                    preset.requires_approval -> "approval"
                    true -> "observe"
                  end}
                </span>
              </div>
              <p class="mt-2 text-xs text-zinc-500">
                classes {join_or_none(preset.side_effect_classes || [])}
              </p>
            </div>
          </div>

          <div id="settings-tool-bundle-presets" class="mt-4 grid gap-3 md:grid-cols-2 xl:grid-cols-4">
            <div
              :for={bundle <- @tool_bundles}
              id={"settings-tool-bundle-#{bundle.name}"}
              class="rounded-lg border border-zinc-200 bg-zinc-50 p-4 text-sm"
            >
              <p class="font-semibold text-zinc-950">{bundle.name}</p>
              <p class="mt-1 text-xs text-zinc-500">{bundle.description}</p>
              <p class="mt-2 text-xs text-zinc-500">
                tools {length(bundle.tools)} / approval {if bundle.requires_approval,
                  do: "required",
                  else: "not required"}
              </p>
            </div>
          </div>
        </section>

        <div class="grid gap-6 xl:grid-cols-2">
          <section class="rounded-lg border border-zinc-200 bg-white p-5">
            <h2 class="text-base font-semibold text-zinc-950">Provider Routes</h2>
            <div class="mt-4 space-y-2">
              <div :for={provider <- @providers} class="rounded-lg border border-zinc-200 p-3 text-sm">
                <p class="font-medium text-zinc-950">{provider.name}</p>
                <p class="mt-1 text-zinc-600">
                  {provider.kind} / {provider.model} / env {provider.api_key_env || "none"}
                </p>
              </div>
              <p :if={@providers == []} class="text-sm text-zinc-500">No providers configured.</p>
            </div>
          </section>

          <section class="rounded-lg border border-zinc-200 bg-white p-5">
            <h2 class="text-base font-semibold text-zinc-950">Credential Pools</h2>
            <div class="mt-4 space-y-2">
              <div
                :for={pool <- @credential_pools}
                class="rounded-lg border border-zinc-200 p-3 text-sm"
              >
                <p class="font-medium text-zinc-950">{pool.name}</p>
                <p class="mt-1 text-zinc-600">{pool.kind} / {pool.status}</p>
                <p class="mt-1 text-xs text-zinc-500">env {join_or_none(pool.env_vars || [])}</p>
              </div>
              <p :if={@credential_pools == []} class="text-sm text-zinc-500">
                No credential pools configured.
              </p>
            </div>
          </section>

          <section class="rounded-lg border border-zinc-200 bg-white p-5">
            <h2 class="text-base font-semibold text-zinc-950">Tool Policies</h2>
            <div class="mt-4 space-y-2">
              <div
                :for={policy <- @tool_policies}
                class="rounded-lg border border-zinc-200 p-3 text-sm"
              >
                <p class="font-medium text-zinc-950">{policy.scope} policy #{policy.id}</p>
                <p class="mt-1 text-xs text-zinc-500">
                  tools {join_or_none(policy.allowed_tools || [])}
                </p>
              </div>
              <p :if={@tool_policies == []} class="text-sm text-zinc-500">
                No tool policies configured.
              </p>
            </div>
          </section>

          <section class="rounded-lg border border-zinc-200 bg-white p-5">
            <div class="flex items-start justify-between gap-4">
              <div>
                <h2 class="text-base font-semibold text-zinc-950">Token Spend Guardrails</h2>
                <p class="mt-1 text-sm text-zinc-500">
                  Active budgets block model spend once their token limit is exceeded.
                </p>
              </div>
            </div>
            <.form
              :let={f}
              for={%{}}
              as={:budget}
              id="settings-budget-form"
              phx-change="validate-budget"
              phx-submit="create-budget"
              class="mt-4 space-y-3 rounded-lg border border-zinc-200 bg-zinc-50 p-4 text-sm"
            >
              <div class="grid gap-3 md:grid-cols-2">
                <label class="space-y-1">
                  <span class="text-xs font-medium text-zinc-700">Name</span>
                  <input
                    type="text"
                    name={f[:name].name}
                    value={@budget_form["name"]}
                    class="w-full rounded-md border border-zinc-200 bg-white px-3 py-2 text-sm text-zinc-950"
                  />
                  <p :if={budget_error(@budget_errors, :name) != ""} class="text-xs text-red-700">
                    {budget_error(@budget_errors, :name)}
                  </p>
                </label>
                <label class="space-y-1">
                  <span class="text-xs font-medium text-zinc-700">Agent</span>
                  <select
                    name={f[:agent_id].name}
                    class="w-full rounded-md border border-zinc-200 bg-white px-3 py-2 text-sm text-zinc-950"
                  >
                    <option value="" selected={@budget_form["agent_id"] in [nil, ""]}>
                      Workspace
                    </option>
                    <option
                      :for={agent <- @agents}
                      value={agent.id}
                      selected={to_string(agent.id) == to_string(@budget_form["agent_id"])}
                    >
                      {agent.name}
                    </option>
                  </select>
                </label>
                <label class="space-y-1">
                  <span class="text-xs font-medium text-zinc-700">Category</span>
                  <select
                    name={f[:category].name}
                    class="w-full rounded-md border border-zinc-200 bg-white px-3 py-2 text-sm text-zinc-950"
                  >
                    <option value="" selected={@budget_form["category"] in [nil, ""]}>All</option>
                    <option
                      :for={category <- ~w(chat planning eval embedding tool)}
                      value={category}
                      selected={category == @budget_form["category"]}
                    >
                      {category}
                    </option>
                  </select>
                </label>
                <label class="space-y-1">
                  <span class="text-xs font-medium text-zinc-700">Period</span>
                  <select
                    name={f[:period].name}
                    class="w-full rounded-md border border-zinc-200 bg-white px-3 py-2 text-sm text-zinc-950"
                  >
                    <option
                      :for={period <- ~w(daily weekly monthly total)}
                      value={period}
                      selected={period == @budget_form["period"]}
                    >
                      {period}
                    </option>
                  </select>
                </label>
                <label class="space-y-1 md:col-span-2">
                  <span class="text-xs font-medium text-zinc-700">Token Limit</span>
                  <input
                    type="number"
                    min="1"
                    name={f[:token_limit].name}
                    value={@budget_form["token_limit"]}
                    class="w-full rounded-md border border-zinc-200 bg-white px-3 py-2 text-sm text-zinc-950"
                  />
                  <p
                    :if={budget_error(@budget_errors, :token_limit) != ""}
                    class="text-xs text-red-700"
                  >
                    {budget_error(@budget_errors, :token_limit)}
                  </p>
                </label>
              </div>
              <button
                type="submit"
                class="rounded-md bg-zinc-950 px-3 py-2 text-sm font-semibold text-white"
              >
                Create Budget
              </button>
            </.form>
            <div class="mt-4 space-y-2">
              <div :for={budget <- @budgets} class="rounded-lg border border-zinc-200 p-3 text-sm">
                <div class="flex flex-wrap items-start justify-between gap-3">
                  <div>
                    <p class="font-medium text-zinc-950">{budget["budget"].name}</p>
                    <p class="mt-1 text-zinc-600">
                      {budget_agent_name(budget["budget"].agent_id, @agents_by_id)} / {budget[
                        "budget"
                      ].category || "all"} / {budget["budget"].period}
                    </p>
                  </div>
                  <p class="text-xs font-semibold uppercase text-zinc-500">
                    {budget["usage_status"]["status"]}
                  </p>
                </div>
                <p class="mt-2 text-xs text-zinc-500">
                  tokens {budget["usage_status"]["used_tokens"]} / {budget["budget"].token_limit ||
                    "unbounded"} ({budget_ratio(budget["usage_status"]["token_ratio"])})
                </p>
              </div>
              <p :if={@budgets == []} class="text-sm text-zinc-500">No budgets configured.</p>
            </div>
          </section>
        </div>
      <% else %>
        <section class="rounded-lg border border-zinc-200 bg-white p-8 text-sm text-zinc-500">
          No workspaces yet.
        </section>
      <% end %>
    </section>
    """
  end
end
