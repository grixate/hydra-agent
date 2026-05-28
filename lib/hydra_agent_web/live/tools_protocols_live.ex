defmodule HydraAgentWeb.ToolsProtocolsLive do
  use HydraAgentWeb, :live_view

  alias HydraAgent.{Browser, Connectors, Gateways, MCP, Runtime, Skills}
  alias HydraAgent.Tools.Registry
  alias HydraAgentWeb.ControlShell

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Tools And Protocols")
     |> assign(:workspace_id, nil)
     |> assign(:tools, Registry.all())
     |> assign(:bundles, Runtime.tool_bundles())
     |> assign(:connector_specs, Connectors.provider_specs())
     |> assign(:permission_presets, Connectors.permission_presets())
     |> load_workspaces()}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    workspace_id = selected_workspace_id(socket.assigns.workspaces, params["workspace_id"])

    socket =
      socket
      |> assign(:workspace_id, workspace_id)
      |> load_workspace_state()

    {:noreply, socket}
  end

  @impl true
  def handle_event("discover-mcp", %{"id" => id}, socket) do
    server = MCP.get_server_for_workspace!(socket.assigns.workspace_id, id)

    socket =
      case MCP.discover_server(server, %{
             "workspace_id" => socket.assigns.workspace_id,
             "workspace_root" => File.cwd!()
           }) do
        {:ok, _server} ->
          put_flash(socket, :info, "MCP discovery updated")

        {:error, error} ->
          put_flash(socket, :error, "MCP discovery failed: #{inspect(error)}")
      end

    {:noreply, load_workspace_state(socket)}
  end

  def handle_event("stop-mcp-session", %{"id" => id}, socket) do
    server = MCP.get_server_for_workspace!(socket.assigns.workspace_id, id)

    socket =
      case MCP.stop_stdio_session(server) do
        :ok ->
          put_flash(socket, :info, "MCP stdio session stopped")

        {:error, :not_found} ->
          put_flash(socket, :info, "No active MCP stdio session")

        {:error, error} ->
          put_flash(socket, :error, "MCP stdio session stop failed: #{inspect(error)}")
      end

    {:noreply, load_workspace_state(socket)}
  end

  def handle_event("create-policy", %{"policy" => params}, socket) do
    attrs =
      params
      |> parse_policy_params()
      |> Map.put("workspace_id", socket.assigns.workspace_id)

    socket =
      case Runtime.create_tool_policy(attrs) do
        {:ok, _policy} ->
          socket
          |> put_flash(:info, "Tool policy created")
          |> load_workspace_state()

        {:error, changeset} ->
          put_flash(socket, :error, "Policy rejected: #{format_changeset_errors(changeset)}")
      end

    {:noreply, socket}
  end

  def handle_event("create-connector", %{"connector" => params}, socket) do
    attrs = stringify_keys(params)

    socket =
      with {:ok, config} <- parse_config_map(attrs["config"]),
           {:ok, _account} <-
             attrs
             |> Map.put("config", config)
             |> Map.put("workspace_id", socket.assigns.workspace_id)
             |> Connectors.create_account() do
        socket |> put_flash(:info, "Connector created") |> load_workspace_state()
      else
        {:error, :invalid_config_json} ->
          put_flash(socket, :error, "Connector rejected: config must be a JSON object")

        {:error, %Ecto.Changeset{} = changeset} ->
          put_flash(socket, :error, "Connector rejected: #{format_changeset_errors(changeset)}")
      end

    {:noreply, socket}
  end

  def handle_event("health-check-connector", %{"id" => id}, socket) do
    account = Connectors.get_account_for_workspace!(socket.assigns.workspace_id, id)

    socket =
      case Connectors.health_check(account) do
        {:ok, _account} ->
          socket |> put_flash(:info, "Connector health checked") |> load_workspace_state()

        {:error, changeset} ->
          put_flash(socket, :error, "Health check failed: #{format_changeset_errors(changeset)}")
      end

    {:noreply, socket}
  end

  def handle_event("grant-connector-agent", %{"connector_grant" => params}, socket) do
    params = stringify_keys(params)

    socket =
      with account_id when not is_nil(account_id) <- parse_optional_id(params["account_id"]),
           account <-
             Connectors.get_account_for_workspace!(socket.assigns.workspace_id, account_id),
           {:ok, _account} <-
             Connectors.grant_agent_permission(account, %{
               "agent_id" => params["agent_id"],
               "action" => params["action"],
               "mode" => params["mode"],
               "granted_by" => "tools_protocols_live"
             }) do
        socket |> put_flash(:info, "Connector permission granted") |> load_workspace_state()
      else
        nil -> put_flash(socket, :error, "Select a connector account")
        {:error, error} -> put_flash(socket, :error, "Connector grant failed: #{inspect(error)}")
      end

    {:noreply, socket}
  end

  def handle_event("request-connector-action", %{"connector_action" => params}, socket) do
    params = stringify_keys(params)

    socket =
      with account_id when not is_nil(account_id) <- parse_optional_id(params["account_id"]),
           account <-
             Connectors.get_account_for_workspace!(socket.assigns.workspace_id, account_id),
           {:ok, _action} <-
             Connectors.request_action(account, %{
               "action" => params["action"],
               "agent_id" => parse_optional_id(params["agent_id"]),
               "input" => parse_json_map(params["input"]),
               "approval_mode" => params["approval_mode"],
               "requested_by" => "tools_protocols_live"
             }) do
        socket |> put_flash(:info, "Connector action recorded") |> load_workspace_state()
      else
        nil -> put_flash(socket, :error, "Select a connector account")
        {:error, error} -> put_flash(socket, :error, "Connector action failed: #{inspect(error)}")
      end

    {:noreply, socket}
  end

  def handle_event("approve-connector-action", %{"id" => id}, socket) do
    action = Connectors.get_action_for_workspace!(socket.assigns.workspace_id, id)

    socket =
      case Connectors.approve_action(action, %{"approved_by" => "tools_protocols_live"}) do
        {:ok, _action} ->
          socket |> put_flash(:info, "Connector action approved") |> load_workspace_state()

        {:error, error} ->
          put_flash(socket, :error, "Approval failed: #{inspect(error)}")
      end

    {:noreply, socket}
  end

  def handle_event("reject-connector-action", %{"id" => id}, socket) do
    action = Connectors.get_action_for_workspace!(socket.assigns.workspace_id, id)

    socket =
      case Connectors.reject_action(action, %{"rejected_by" => "tools_protocols_live"}) do
        {:ok, _action} ->
          socket |> put_flash(:info, "Connector action rejected") |> load_workspace_state()

        {:error, error} ->
          put_flash(socket, :error, "Reject failed: #{inspect(error)}")
      end

    {:noreply, socket}
  end

  def handle_event("scan-skill-import", %{"skill_import" => params}, socket) do
    socket =
      case Skills.scan_skill_import(socket.assigns.workspace_id, params) do
        {:ok, _skill_import} ->
          socket |> put_flash(:info, "Skill import scanned") |> load_workspace_state()

        {:error, error} ->
          put_flash(socket, :error, "Skill scan failed: #{inspect(error)}")
      end

    {:noreply, socket}
  end

  def handle_event("approve-skill-import", %{"id" => id}, socket) do
    skill_import = Skills.get_skill_import_for_workspace!(socket.assigns.workspace_id, id)

    socket =
      case Skills.approve_skill_import(skill_import, %{"approved_by" => "tools_protocols_live"}) do
        {:ok, _result} ->
          socket |> put_flash(:info, "Skill import installed") |> load_workspace_state()

        {:error, error} ->
          put_flash(socket, :error, "Skill install failed: #{inspect(error)}")
      end

    {:noreply, socket}
  end

  def handle_event("reject-skill-import", %{"id" => id}, socket) do
    skill_import = Skills.get_skill_import_for_workspace!(socket.assigns.workspace_id, id)

    socket =
      case Skills.reject_skill_import(skill_import, %{"rejected_by" => "tools_protocols_live"}) do
        {:ok, _skill_import} ->
          socket |> put_flash(:info, "Skill import rejected") |> load_workspace_state()

        {:error, error} ->
          put_flash(socket, :error, "Skill reject failed: #{inspect(error)}")
      end

    {:noreply, socket}
  end

  defp load_workspaces(socket) do
    assign(socket, :workspaces, Runtime.list_workspaces())
  end

  defp load_workspace_state(%{assigns: %{workspace_id: nil}} = socket) do
    socket
    |> assign(:policies, [])
    |> assign(:credential_pools, [])
    |> assign(:mcp_servers, [])
    |> assign(:mcp_session_statuses, %{})
    |> assign(:webhooks, [])
    |> assign(:connector_accounts, [])
    |> assign(:connector_actions, [])
    |> assign(:agents, [])
    |> assign(:browser_sessions, [])
    |> assign(:skill_imports, [])
  end

  defp load_workspace_state(%{assigns: %{workspace_id: workspace_id}} = socket) do
    mcp_servers = MCP.list_servers(workspace_id)

    socket
    |> assign(:policies, Runtime.list_tool_policies(workspace_id))
    |> assign(:credential_pools, Runtime.list_credential_pools(workspace_id))
    |> assign(:mcp_servers, mcp_servers)
    |> assign(
      :mcp_session_statuses,
      Map.new(mcp_servers, &{&1.id, stdio_session_status(&1)})
    )
    |> assign(:webhooks, Gateways.list_webhooks(workspace_id))
    |> assign(:connector_accounts, Connectors.list_accounts(workspace_id))
    |> assign(:connector_actions, Connectors.list_actions(workspace_id, limit: 25))
    |> assign(:agents, Runtime.list_agents(workspace_id))
    |> assign(:browser_sessions, Browser.list_sessions(workspace_id))
    |> assign(:skill_imports, Skills.list_skill_imports(workspace_id))
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

  defp parse_optional_id(nil), do: nil
  defp parse_optional_id(""), do: nil
  defp parse_optional_id(id) when is_integer(id), do: id

  defp parse_optional_id(id) when is_binary(id) do
    case Integer.parse(id) do
      {parsed, ""} -> parsed
      _other -> nil
    end
  end

  defp stringify_keys(map),
    do: Map.new(map || %{}, fn {key, value} -> {to_string(key), value} end)

  defp parse_json_map(nil), do: %{}
  defp parse_json_map(""), do: %{}

  defp parse_json_map(value) when is_binary(value) do
    case Jason.decode(value) do
      {:ok, map} when is_map(map) -> map
      _error -> %{"text" => value}
    end
  end

  defp parse_json_map(value) when is_map(value), do: value
  defp parse_json_map(value), do: %{"value" => value}

  defp parse_config_map(nil), do: {:ok, %{}}
  defp parse_config_map(""), do: {:ok, %{}}
  defp parse_config_map(value) when is_map(value), do: {:ok, value}

  defp parse_config_map(value) when is_binary(value) do
    case Jason.decode(value) do
      {:ok, map} when is_map(map) -> {:ok, map}
      _error -> {:error, :invalid_config_json}
    end
  end

  defp parse_config_map(_value), do: {:error, :invalid_config_json}

  defp join_or_none([]), do: "none"
  defp join_or_none(values), do: Enum.join(values, ", ")

  defp connector_health_status(account) do
    get_in(account.last_health || %{}, ["status"]) || "unknown"
  end

  defp connector_readiness_status(account), do: Connectors.setup_readiness(account)["status"]

  defp connector_readiness_findings(account) do
    account
    |> Connectors.setup_readiness()
    |> Map.get("findings", [])
  end

  defp connector_setup_guide(account), do: Connectors.provider_setup_guide(account.provider)

  defp connector_missing_config(account) do
    readiness = Connectors.setup_readiness(account)

    (readiness["missing_required_config"] || []) ++
      (readiness["missing_recommended_config"] || [])
  end

  defp connector_config_help(account, field) do
    account
    |> connector_setup_guide()
    |> get_in(["config_help", field])
  end

  defp connector_config_summary(account) do
    account.config
    |> Kernel.||(%{})
    |> Map.keys()
    |> Enum.sort()
    |> join_or_none()
  end

  defp connector_grant_count(account) do
    account
    |> Connectors.agent_permission_grants()
    |> map_size()
  end

  defp connector_write_actions(account) do
    account.provider
    |> connector_spec()
    |> case do
      %{write_actions: actions} -> actions
      _spec -> []
    end
  end

  defp connector_spec(provider),
    do: Enum.find(Connectors.provider_specs(), &(&1.provider == provider))

  defp policy_bundles(policy), do: get_in(policy.metadata || %{}, ["tool_bundles"]) || []

  defp policy_warnings(policy) do
    side_effect_classes = policy.side_effect_classes || []
    dangerous_classes = side_effect_classes -- ["read_only"]

    []
    |> maybe_add_warning(
      dangerous_classes != [] and policy.requires_approval == false,
      "Dangerous side effects can run without approval"
    )
    |> maybe_add_warning(
      "*" in (policy.network_allowlist || []),
      "Network allows every host"
    )
    |> maybe_add_warning(
      "*" in (policy.shell_allowlist || []),
      "Shell allows every command"
    )
    |> maybe_add_warning(
      "*" in (policy.filesystem_allowlist || []),
      "Filesystem allows every path"
    )
  end

  defp policy_warning_count(policy), do: length(policy_warnings(policy))

  defp maybe_add_warning(warnings, true, warning), do: warnings ++ [warning]
  defp maybe_add_warning(warnings, _condition, _warning), do: warnings

  defp parse_policy_params(params) do
    params
    |> Enum.reduce(%{}, fn {key, value}, attrs ->
      case key do
        key
        when key in [
               "tool_bundles",
               "allowed_tools",
               "side_effect_classes",
               "network_allowlist",
               "shell_allowlist",
               "shell_env_allowlist",
               "filesystem_allowlist",
               "filesystem_denylist"
             ] ->
          Map.put(attrs, key, split_list(value))

        "requires_approval" ->
          Map.put(attrs, key, value in ["true", "on", true])

        key ->
          Map.put(attrs, key, value)
      end
    end)
  end

  defp split_list(value) when is_binary(value) do
    value
    |> String.split([",", "\n"], trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp split_list(value) when is_list(value), do: value
  defp split_list(_value), do: []

  defp format_changeset_errors(changeset) do
    changeset
    |> Ecto.Changeset.traverse_errors(fn {message, opts} ->
      Enum.reduce(opts, message, fn {key, value}, acc ->
        String.replace(acc, "%{#{key}}", to_string(value))
      end)
    end)
    |> Enum.map(fn {field, messages} -> "#{field} #{Enum.join(messages, ", ")}" end)
    |> Enum.join("; ")
  end

  defp protocol_status_counts(records) do
    records
    |> Enum.frequencies_by(& &1.status)
    |> Enum.sort()
  end

  defp discovery_items(server, key) do
    server.metadata
    |> Kernel.||(%{})
    |> get_in(["discovery", key])
    |> case do
      items when is_list(items) -> items
      _items -> []
    end
  end

  defp discovery_names(items) do
    items
    |> Enum.map(fn
      %{"name" => name} -> name
      %{"uri" => uri} -> uri
      item when is_binary(item) -> item
      _item -> nil
    end)
    |> Enum.reject(&is_nil/1)
    |> Enum.take(4)
    |> join_or_none()
  end

  defp stdio_session_status(%{transport: "stdio", config: %{"persistent" => true}} = server) do
    MCP.stdio_session_status(server)
  end

  defp stdio_session_status(_server), do: %{"active" => false}

  @impl true
  def render(assigns) do
    ~H"""
    <section id="tools-protocols" class="space-y-8">
      <ControlShell.header
        active={:tools}
        description="Built-in tools, policy grants, bundles, MCP servers, webhooks, env refs, allowlists, and protocol health."
        eyebrow="Tools and protocols"
        title="Tools And Protocols"
        workspaces={@workspaces}
        workspace_id={@workspace_id}
      />

      <%= if @workspace_id do %>
        <div class="grid gap-4 md:grid-cols-2 xl:grid-cols-4">
          <div class="rounded-lg border border-zinc-200 bg-white p-4">
            <p class="text-xs font-semibold uppercase tracking-[0.14em] text-zinc-500">Tools</p>
            <p class="mt-3 text-3xl font-semibold text-zinc-950">{length(@tools)}</p>
            <p class="mt-1 text-sm text-zinc-600">built-in registry entries</p>
          </div>
          <div class="rounded-lg border border-zinc-200 bg-white p-4">
            <p class="text-xs font-semibold uppercase tracking-[0.14em] text-zinc-500">Bundles</p>
            <p class="mt-3 text-3xl font-semibold text-zinc-950">{length(@bundles)}</p>
            <p class="mt-1 text-sm text-zinc-600">policy templates</p>
          </div>
          <div class="rounded-lg border border-zinc-200 bg-white p-4">
            <p class="text-xs font-semibold uppercase tracking-[0.14em] text-zinc-500">MCP</p>
            <p class="mt-3 text-3xl font-semibold text-zinc-950">{length(@mcp_servers)}</p>
            <p class="mt-1 text-sm text-zinc-600">configured protocol servers</p>
          </div>
          <div class="rounded-lg border border-zinc-200 bg-white p-4">
            <p class="text-xs font-semibold uppercase tracking-[0.14em] text-zinc-500">
              Credentials
            </p>
            <p class="mt-3 text-3xl font-semibold text-zinc-950">{length(@credential_pools)}</p>
            <p class="mt-1 text-sm text-zinc-600">env-backed pools</p>
          </div>
        </div>

        <div class="grid gap-6 xl:grid-cols-[1.15fr_0.85fr]">
          <section class="space-y-3">
            <h2 class="text-lg font-semibold text-zinc-950">Built-In Tools</h2>
            <div id="tools-registry" class="grid gap-3 md:grid-cols-2">
              <div
                :for={tool <- @tools}
                id={"tools-registry-#{tool.name}"}
                class="rounded-lg border border-zinc-200 bg-white p-4"
              >
                <div class="flex items-start justify-between gap-3">
                  <div class="min-w-0">
                    <p class="truncate text-sm font-semibold text-zinc-950">{tool.name}</p>
                    <p class="mt-1 line-clamp-2 text-sm text-zinc-600">{tool.description}</p>
                  </div>
                  <span class="text-xs font-medium uppercase text-zinc-500">
                    {tool.side_effect_class}
                  </span>
                </div>
                <p class="mt-2 text-xs text-zinc-500">
                  timeout {tool.timeout_ms || 30_000}ms / {if tool.approval_sensitive,
                    do: "approval-sensitive",
                    else: "non-sensitive"}
                </p>
              </div>
            </div>
          </section>

          <section class="space-y-3">
            <h2 class="text-lg font-semibold text-zinc-950">Tool Bundles</h2>
            <div id="tools-bundles" class="space-y-2">
              <div
                :for={bundle <- @bundles}
                id={"tools-bundle-#{bundle.name}"}
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
                  tools {join_or_none(bundle.tools)} / classes {join_or_none(
                    bundle.side_effect_classes
                  )}
                </p>
              </div>
            </div>
          </section>
        </div>

        <div class="grid gap-6 xl:grid-cols-3">
          <section class="space-y-3">
            <h2 class="text-lg font-semibold text-zinc-950">Connectors</h2>
            <.form
              for={%{}}
              as={:connector}
              id="tools-connector-editor"
              phx-submit="create-connector"
              class="space-y-3 rounded-lg border border-zinc-200 bg-white p-4 text-sm"
            >
              <select
                name="connector[provider]"
                class="block w-full rounded-md border-zinc-300 text-sm"
              >
                <option :for={spec <- @connector_specs} value={spec.provider}>{spec.label}</option>
              </select>
              <input
                name="connector[slug]"
                class="block w-full rounded-md border-zinc-300 text-sm"
                placeholder="connector-slug"
              />
              <input
                name="connector[display_name]"
                class="block w-full rounded-md border-zinc-300 text-sm"
                placeholder="Display name"
              />
              <input
                name="connector[credential_env]"
                class="block w-full rounded-md border-zinc-300 text-sm"
                placeholder="OPTIONAL_TOKEN_ENV"
              />
              <input
                name="connector[refresh_env]"
                class="block w-full rounded-md border-zinc-300 text-sm"
                placeholder="OPTIONAL_REFRESH_ENV"
              />
              <textarea
                name="connector[config]"
                class="block min-h-[4.5rem] w-full rounded-md border-zinc-300 text-sm"
                placeholder='{"calendar_id":"primary","author_urn":"urn:li:person:..."}'
              ></textarea>
              <button
                type="submit"
                class="rounded-md bg-zinc-950 px-3 py-2 text-xs font-semibold text-white"
              >
                Add Connector
              </button>
            </.form>

            <div id="tools-connectors" class="space-y-2">
              <div
                :for={account <- @connector_accounts}
                id={"tools-connector-#{account.id}"}
                class="rounded-lg border border-zinc-200 bg-white p-4"
              >
                <p class="text-sm font-semibold text-zinc-950">{account.display_name}</p>
                <p class="mt-1 text-xs text-zinc-500">
                  {account.provider} / {account.status} / env {account.credential_env || "none"}
                </p>
                <p class="mt-2 text-xs text-zinc-500">
                  capabilities {join_or_none(account.capabilities || [])}
                </p>
                <p class="mt-1 text-xs text-zinc-500">
                  health {connector_health_status(account)} / checked {get_in(
                    account.last_health || %{},
                    ["checked_at"]
                  ) || "never"}
                </p>
                <p class="mt-1 text-xs text-zinc-500">
                  config {connector_config_summary(account)}
                </p>
                <p class={[
                  "mt-1 text-xs font-semibold",
                  connector_readiness_status(account) == "ready" && "text-emerald-700",
                  connector_readiness_status(account) == "setup_pending" && "text-amber-700",
                  connector_readiness_status(account) == "needs_attention" && "text-red-700"
                ]}>
                  readiness {connector_readiness_status(account)} / grants {connector_grant_count(
                    account
                  )}
                </p>
                <p
                  :for={finding <- connector_readiness_findings(account)}
                  class="mt-1 text-xs text-amber-700"
                >
                  {finding["reason"]} {join_or_none(finding["fields"] || [])}
                </p>
                <div class="mt-3 rounded-md border border-zinc-100 bg-zinc-50 p-3">
                  <p class="text-xs font-semibold uppercase tracking-[0.12em] text-zinc-500">
                    Setup Steps
                  </p>
                  <p
                    :for={step <- connector_setup_guide(account)["steps"]}
                    class="mt-1 text-xs text-zinc-600"
                  >
                    {step}
                  </p>
                  <p
                    :for={field <- connector_missing_config(account)}
                    class="mt-1 text-xs text-amber-700"
                  >
                    {field}: {connector_config_help(account, field) || "configure this field"}
                  </p>
                </div>
                <p :if={map_size(account.last_error || %{}) > 0} class="mt-1 text-xs text-red-700">
                  {inspect(account.last_error)}
                </p>
                <button
                  type="button"
                  phx-click="health-check-connector"
                  phx-value-id={account.id}
                  class="mt-3 rounded-md border border-zinc-200 px-2 py-1 text-xs font-medium text-zinc-700"
                >
                  Check Health
                </button>
                <.form
                  :if={@agents != [] and connector_write_actions(account) != []}
                  for={%{}}
                  as={:connector_grant}
                  phx-submit="grant-connector-agent"
                  class="mt-3 grid gap-2"
                >
                  <input type="hidden" name="connector_grant[account_id]" value={account.id} />
                  <select
                    name="connector_grant[agent_id]"
                    class="rounded-md border-zinc-300 text-xs"
                  >
                    <option :for={agent <- @agents} value={agent.id}>{agent.name}</option>
                  </select>
                  <div class="grid grid-cols-2 gap-2">
                    <select
                      name="connector_grant[action]"
                      class="rounded-md border-zinc-300 text-xs"
                    >
                      <option :for={action <- connector_write_actions(account)} value={action}>
                        {action}
                      </option>
                      <option value="*">All writes</option>
                    </select>
                    <select name="connector_grant[mode]" class="rounded-md border-zinc-300 text-xs">
                      <option value="approval_required">Approval required</option>
                      <option value="trusted">Trusted</option>
                    </select>
                  </div>
                  <button
                    type="submit"
                    class="rounded-md border border-zinc-200 px-2 py-1 text-xs font-medium text-zinc-700"
                  >
                    Grant Agent
                  </button>
                </.form>
              </div>
              <p
                :if={@connector_accounts == []}
                class="rounded-lg border border-zinc-200 bg-white p-4 text-sm text-zinc-500"
              >
                No connectors configured.
              </p>
            </div>
          </section>

          <section class="space-y-3">
            <h2 class="text-lg font-semibold text-zinc-950">Connector Actions</h2>
            <.form
              for={%{}}
              as={:connector_action}
              id="tools-connector-action-editor"
              phx-submit="request-connector-action"
              class="space-y-3 rounded-lg border border-zinc-200 bg-white p-4 text-sm"
            >
              <select
                name="connector_action[account_id]"
                class="block w-full rounded-md border-zinc-300 text-sm"
              >
                <option value="">Select account</option>
                <option :for={account <- @connector_accounts} value={account.id}>
                  {account.display_name} / {account.provider}
                </option>
              </select>
              <input
                name="connector_action[action]"
                class="block w-full rounded-md border-zinc-300 text-sm"
                placeholder="draft, send, search, append_note"
              />
              <select
                name="connector_action[agent_id]"
                class="block w-full rounded-md border-zinc-300 text-sm"
              >
                <option value="">Manual operator request</option>
                <option :for={agent <- @agents} value={agent.id}>{agent.name}</option>
              </select>
              <select
                name="connector_action[approval_mode]"
                class="block w-full rounded-md border-zinc-300 text-sm"
              >
                <option value="approval_required">Approval required</option>
                <option value="trusted">Trusted if granted</option>
              </select>
              <textarea
                name="connector_action[input]"
                class="block min-h-[5rem] w-full rounded-md border-zinc-300 text-sm"
                placeholder='{"text":"Draft this"}'
              ></textarea>
              <button
                type="submit"
                class="rounded-md bg-zinc-950 px-3 py-2 text-xs font-semibold text-white"
              >
                Request Action
              </button>
            </.form>
            <div id="tools-connector-actions" class="space-y-2">
              <div
                :for={action <- @connector_actions}
                id={"tools-connector-action-#{action.id}"}
                class="rounded-lg border border-zinc-200 bg-white p-4"
              >
                <div class="flex items-start justify-between gap-3">
                  <div>
                    <p class="text-sm font-semibold text-zinc-950">
                      {action.provider}:{action.action}
                    </p>
                    <p class="mt-1 text-xs text-zinc-500">
                      {action.side_effect_class} / {action.status}
                    </p>
                  </div>
                  <div :if={action.status == "awaiting_approval"} class="flex gap-2">
                    <button
                      type="button"
                      phx-click="approve-connector-action"
                      phx-value-id={action.id}
                      class="rounded-md bg-emerald-700 px-2 py-1 text-xs font-medium text-white"
                    >
                      Approve
                    </button>
                    <button
                      type="button"
                      phx-click="reject-connector-action"
                      phx-value-id={action.id}
                      class="rounded-md border border-zinc-200 px-2 py-1 text-xs font-medium text-zinc-700"
                    >
                      Reject
                    </button>
                  </div>
                </div>
                <p :if={map_size(action.last_error || %{}) > 0} class="mt-2 text-xs text-red-700">
                  {inspect(action.last_error)}
                </p>
              </div>
              <p
                :if={@connector_actions == []}
                class="rounded-lg border border-zinc-200 bg-white p-4 text-sm text-zinc-500"
              >
                No connector actions yet.
              </p>
            </div>
          </section>

          <section class="space-y-3">
            <h2 class="text-lg font-semibold text-zinc-950">Permission Presets</h2>
            <div id="tools-permission-presets" class="space-y-2">
              <div
                :for={preset <- @permission_presets}
                id={"tools-permission-preset-#{preset.id}"}
                class="rounded-lg border border-zinc-200 bg-white p-4"
              >
                <p class="text-sm font-semibold text-zinc-950">{preset.label}</p>
                <p class="mt-1 text-xs text-zinc-500">
                  classes {join_or_none(preset.side_effect_classes || [])}
                </p>
                <p class="mt-1 text-xs text-zinc-500">
                  approval {if preset.requires_approval, do: "required", else: "not required"}
                </p>
              </div>
            </div>
          </section>
        </div>

        <section class="space-y-3">
          <h2 class="text-lg font-semibold text-zinc-950">Connector Setup Guide</h2>
          <div id="tools-connector-setup-guide" class="grid gap-3 md:grid-cols-2 xl:grid-cols-4">
            <div
              :for={spec <- @connector_specs}
              id={"tools-connector-setup-#{spec.provider}"}
              class="rounded-lg border border-zinc-200 bg-white p-4"
            >
              <p class="text-sm font-semibold text-zinc-950">{spec.label}</p>
              <p class="mt-1 text-xs text-zinc-500">
                env {get_in(spec, [:setup, :credential_env]) || "none"}
              </p>
              <p class="mt-1 text-xs text-zinc-500">
                scopes {join_or_none(get_in(spec, [:setup, :scopes]) || [])}
              </p>
              <p class="mt-1 text-xs text-zinc-500">
                config {join_or_none(get_in(spec, [:setup, :config_fields]) || [])}
              </p>
              <p
                :for={step <- get_in(spec, [:setup, :guide]) || []}
                class="mt-1 text-xs text-zinc-600"
              >
                {step}
              </p>
              <p
                :for={{field, help} <- get_in(spec, [:setup, :config_help]) || %{}}
                class="mt-1 text-xs text-zinc-500"
              >
                {field}: {help}
              </p>
            </div>
          </div>
        </section>

        <div class="grid gap-6 xl:grid-cols-3">
          <section class="space-y-3">
            <h2 class="text-lg font-semibold text-zinc-950">Policies</h2>
            <.form
              :let={f}
              for={%{}}
              as={:policy}
              id="tools-policy-editor"
              phx-submit="create-policy"
              class="space-y-3 rounded-lg border border-amber-200 bg-amber-50 p-4 text-sm"
            >
              <div>
                <p class="font-semibold text-amber-950">Policy Editor</p>
                <p class="mt-1 text-xs text-amber-800">
                  High-risk grants should keep approval enabled and use narrow allowlists.
                </p>
              </div>
              <div class="grid gap-3 md:grid-cols-2">
                <label class="space-y-1">
                  <span class="text-xs font-medium text-amber-950">Bundles</span>
                  <input
                    type="text"
                    name={f[:tool_bundles].name}
                    placeholder="files_read, terminal"
                    class="w-full rounded-md border border-amber-200 bg-white px-3 py-2 text-sm text-zinc-950"
                  />
                </label>
                <label class="space-y-1">
                  <span class="text-xs font-medium text-amber-950">Tools</span>
                  <input
                    type="text"
                    name={f[:allowed_tools].name}
                    placeholder="file_read, shell_command"
                    class="w-full rounded-md border border-amber-200 bg-white px-3 py-2 text-sm text-zinc-950"
                  />
                </label>
                <label class="space-y-1">
                  <span class="text-xs font-medium text-amber-950">Side Effects</span>
                  <input
                    type="text"
                    name={f[:side_effect_classes].name}
                    placeholder="read_only, shell"
                    class="w-full rounded-md border border-amber-200 bg-white px-3 py-2 text-sm text-zinc-950"
                  />
                </label>
                <label class="space-y-1">
                  <span class="text-xs font-medium text-amber-950">Filesystem Allowlist</span>
                  <input
                    type="text"
                    name={f[:filesystem_allowlist].name}
                    placeholder="lib, test"
                    class="w-full rounded-md border border-amber-200 bg-white px-3 py-2 text-sm text-zinc-950"
                  />
                </label>
                <label class="space-y-1">
                  <span class="text-xs font-medium text-amber-950">Network Allowlist</span>
                  <input
                    type="text"
                    name={f[:network_allowlist].name}
                    placeholder="example.com"
                    class="w-full rounded-md border border-amber-200 bg-white px-3 py-2 text-sm text-zinc-950"
                  />
                </label>
                <label class="space-y-1">
                  <span class="text-xs font-medium text-amber-950">Shell Allowlist</span>
                  <input
                    type="text"
                    name={f[:shell_allowlist].name}
                    placeholder="mix test"
                    class="w-full rounded-md border border-amber-200 bg-white px-3 py-2 text-sm text-zinc-950"
                  />
                </label>
              </div>
              <label class="flex items-center gap-2 text-xs font-medium text-amber-950">
                <input type="hidden" name={f[:requires_approval].name} value="false" />
                <input
                  type="checkbox"
                  name={f[:requires_approval].name}
                  value="true"
                  checked
                  class="rounded border-amber-300"
                /> Require approval
              </label>
              <button
                type="submit"
                class="rounded-md bg-zinc-950 px-3 py-2 text-xs font-semibold text-white transition hover:bg-zinc-800"
              >
                Create Policy
              </button>
            </.form>
            <div id="tools-policies" class="space-y-2">
              <div
                :for={policy <- @policies}
                id={"tools-policy-#{policy.id}"}
                class="rounded-lg border border-zinc-200 bg-white p-4"
              >
                <p class="text-sm font-semibold text-zinc-950">
                  {policy.scope} policy #{policy.id}
                </p>
                <p class="mt-2 text-xs text-zinc-500">
                  bundles {join_or_none(policy_bundles(policy))}
                </p>
                <p class="mt-1 text-xs text-zinc-500">
                  tools {join_or_none(policy.allowed_tools || [])}
                </p>
                <p class="mt-1 text-xs text-zinc-500">
                  network {join_or_none(policy.network_allowlist || [])} / shell {join_or_none(
                    policy.shell_allowlist || []
                  )}
                </p>
                <p class="mt-1 text-xs text-zinc-500">
                  files {join_or_none(policy.filesystem_allowlist || [])} / env {join_or_none(
                    policy.shell_env_allowlist || []
                  )}
                </p>
                <p class={[
                  "mt-2 text-xs font-medium",
                  policy_warning_count(policy) == 0 && "text-emerald-700",
                  policy_warning_count(policy) > 0 && "text-amber-700"
                ]}>
                  warnings {policy_warning_count(policy)}
                </p>
                <p
                  :for={warning <- policy_warnings(policy)}
                  class="mt-1 text-xs font-medium text-amber-700"
                >
                  {warning}
                </p>
              </div>
              <div
                :if={@policies == []}
                class="rounded-lg border border-zinc-200 bg-white p-4 text-sm text-zinc-500"
              >
                No tool policies configured.
              </div>
            </div>
          </section>

          <section class="space-y-3">
            <h2 class="text-lg font-semibold text-zinc-950">Credential Pools</h2>
            <div id="tools-credential-pools" class="space-y-2">
              <div
                :for={pool <- @credential_pools}
                id={"tools-credential-pool-#{pool.id}"}
                class="rounded-lg border border-zinc-200 bg-white p-4"
              >
                <p class="text-sm font-semibold text-zinc-950">{pool.name}</p>
                <p class="mt-1 text-sm text-zinc-600">{pool.kind} / {pool.status}</p>
                <p class="mt-2 text-xs text-zinc-500">
                  env {join_or_none(pool.env_vars || [])}
                </p>
              </div>
              <div
                :if={@credential_pools == []}
                class="rounded-lg border border-zinc-200 bg-white p-4 text-sm text-zinc-500"
              >
                No credential pools configured.
              </div>
            </div>
          </section>

          <section class="space-y-3">
            <h2 class="text-lg font-semibold text-zinc-950">MCP Servers</h2>
            <div id="tools-mcp" class="space-y-2">
              <div
                :for={server <- @mcp_servers}
                id={"tools-mcp-#{server.id}"}
                class="rounded-lg border border-zinc-200 bg-white p-4"
              >
                <div class="flex items-start justify-between gap-3">
                  <div class="min-w-0">
                    <p class="truncate text-sm font-semibold text-zinc-950">{server.name}</p>
                    <p class="mt-1 text-xs text-zinc-500">
                      {server.transport} / {server.trust_level} / {server.health_status}
                    </p>
                  </div>
                  <span class="text-xs font-medium uppercase text-zinc-500">{server.status}</span>
                </div>
                <p class="mt-2 text-xs text-zinc-500">
                  tools {join_or_none(server.include_tools || [])} / env {join_or_none(
                    server.env_refs || []
                  )}
                </p>
                <p class="mt-1 text-xs text-zinc-500">
                  resource {server.resource_access} / prompt {server.prompt_access}
                </p>
                <p class="mt-1 text-xs text-zinc-500">
                  discovered tools {discovery_names(discovery_items(server, "tools"))}
                </p>
                <p
                  :if={
                    discovery_items(server, "resources") != [] or
                      discovery_items(server, "prompts") != []
                  }
                  class="mt-1 text-xs text-zinc-500"
                >
                  resources {length(discovery_items(server, "resources"))} / prompts {length(
                    discovery_items(server, "prompts")
                  )}
                </p>
                <p :if={server.last_checked_at} class="mt-1 text-xs text-zinc-500">
                  checked {server.last_checked_at}
                </p>
                <p :if={map_size(server.last_error || %{}) > 0} class="mt-1 text-xs text-red-700">
                  last error {inspect(server.last_error)}
                </p>
                <div
                  :if={server.transport == "stdio" and server.config["persistent"] == true}
                  id={"tools-mcp-session-#{server.id}"}
                  class="mt-2 rounded-md border border-zinc-100 bg-zinc-50 p-2 text-xs text-zinc-600"
                >
                  <% session = Map.get(@mcp_session_statuses, server.id, %{"active" => false}) %>
                  <p>
                    session {if session["active"], do: "active", else: "inactive"} / requests {session[
                      "request_count"
                    ] || 0}
                  </p>
                  <p :if={session["last_used_at"]} class="mt-1">
                    last used {session["last_used_at"]} / idle {session["idle_timeout_ms"]}ms
                  </p>
                  <button
                    id={"tools-mcp-session-stop-#{server.id}"}
                    type="button"
                    phx-click="stop-mcp-session"
                    phx-value-id={server.id}
                    disabled={!session["active"]}
                    class={[
                      "mt-2 rounded-md border px-2 py-1 text-xs font-medium transition",
                      !session["active"] && "cursor-not-allowed border-zinc-100 text-zinc-300",
                      session["active"] && "border-zinc-200 text-zinc-700 hover:border-zinc-400"
                    ]}
                  >
                    Stop Session
                  </button>
                </div>
                <button
                  id={"tools-mcp-discover-#{server.id}"}
                  type="button"
                  phx-click="discover-mcp"
                  phx-value-id={server.id}
                  class="mt-3 rounded-md border border-zinc-200 px-2 py-1 text-xs font-medium text-zinc-700 transition hover:border-zinc-400"
                >
                  Refresh Discovery
                </button>
              </div>
              <div
                :if={@mcp_servers == []}
                class="rounded-lg border border-zinc-200 bg-white p-4 text-sm text-zinc-500"
              >
                No MCP servers configured.
              </div>
            </div>
          </section>

          <section class="space-y-3">
            <h2 class="text-lg font-semibold text-zinc-950">Webhooks</h2>
            <div id="tools-webhooks" class="space-y-2">
              <div
                :for={webhook <- @webhooks}
                id={"tools-webhook-#{webhook.id}"}
                class="rounded-lg border border-zinc-200 bg-white p-4"
              >
                <div class="flex items-start justify-between gap-3">
                  <div class="min-w-0">
                    <p class="truncate text-sm font-semibold text-zinc-950">{webhook.name}</p>
                    <p class="mt-1 text-xs text-zinc-500">{webhook.target_type} / {webhook.status}</p>
                  </div>
                  <span class={[
                    "text-xs font-medium uppercase",
                    map_size(webhook.last_error || %{}) > 0 && "text-red-700",
                    map_size(webhook.last_error || %{}) == 0 && "text-emerald-700"
                  ]}>
                    {if map_size(webhook.last_error || %{}) > 0, do: "error", else: "healthy"}
                  </span>
                </div>
                <p class="mt-2 text-xs text-zinc-500">token env {webhook.token_env}</p>
                <p class="mt-1 text-xs text-zinc-500">
                  last error {if map_size(webhook.last_error || %{}) > 0,
                    do: inspect(webhook.last_error),
                    else: "none"}
                </p>
              </div>
              <div
                :if={@webhooks == []}
                class="rounded-lg border border-zinc-200 bg-white p-4 text-sm text-zinc-500"
              >
                No webhooks configured.
              </div>
            </div>
          </section>
        </div>

        <div class="grid gap-6 xl:grid-cols-2">
          <section class="space-y-3">
            <h2 class="text-lg font-semibold text-zinc-950">Skill Hub Imports</h2>
            <.form
              for={%{}}
              as={:skill_import}
              id="tools-skill-import-editor"
              phx-submit="scan-skill-import"
              class="space-y-3 rounded-lg border border-zinc-200 bg-white p-4 text-sm"
            >
              <select
                name="skill_import[source_type]"
                class="block w-full rounded-md border-zinc-300 text-sm"
              >
                <option value="local_path">Local path</option>
                <option value="github">GitHub repo/path/ref</option>
                <option value="raw">Raw SKILL.md</option>
              </select>
              <input
                name="skill_import[source_url]"
                class="block w-full rounded-md border-zinc-300 text-sm"
                placeholder="https://github.com/org/repo.git"
              />
              <input
                name="skill_import[path]"
                class="block w-full rounded-md border-zinc-300 text-sm"
                placeholder="/path/to/skill or skills/example"
              />
              <input
                name="skill_import[source_ref]"
                class="block w-full rounded-md border-zinc-300 text-sm"
                placeholder="branch, tag, or commit"
              />
              <textarea
                name="skill_import[markdown]"
                class="block min-h-[5rem] w-full rounded-md border-zinc-300 text-sm"
                placeholder="# Raw SKILL.md"
              ></textarea>
              <button
                type="submit"
                class="rounded-md bg-zinc-950 px-3 py-2 text-xs font-semibold text-white"
              >
                Scan Import
              </button>
            </.form>
            <div id="tools-skill-imports" class="space-y-2">
              <div
                :for={skill_import <- @skill_imports}
                id={"tools-skill-import-#{skill_import.id}"}
                class="rounded-lg border border-zinc-200 bg-white p-4"
              >
                <div class="flex items-start justify-between gap-3">
                  <div>
                    <p class="text-sm font-semibold text-zinc-950">
                      {skill_import.skill_attrs["name"] || "Imported skill"}
                    </p>
                    <p class="mt-1 text-xs text-zinc-500">
                      {skill_import.source_type} / {skill_import.status} / files {length(
                        skill_import.file_manifest || []
                      )}
                    </p>
                  </div>
                  <div :if={skill_import.status == "scanned"} class="flex gap-2">
                    <button
                      type="button"
                      phx-click="approve-skill-import"
                      phx-value-id={skill_import.id}
                      class="rounded-md bg-emerald-700 px-2 py-1 text-xs font-medium text-white"
                    >
                      Install
                    </button>
                    <button
                      type="button"
                      phx-click="reject-skill-import"
                      phx-value-id={skill_import.id}
                      class="rounded-md border border-zinc-200 px-2 py-1 text-xs font-medium text-zinc-700"
                    >
                      Reject
                    </button>
                  </div>
                </div>
                <p
                  :for={warning <- Enum.take(skill_import.warnings || [], 3)}
                  class="mt-1 text-xs text-amber-700"
                >
                  {warning["code"]}: {warning["message"]}
                </p>
              </div>
              <p
                :if={@skill_imports == []}
                class="rounded-lg border border-zinc-200 bg-white p-4 text-sm text-zinc-500"
              >
                No skill imports scanned.
              </p>
            </div>
          </section>

          <section class="space-y-3">
            <h2 class="text-lg font-semibold text-zinc-950">Browser Sessions</h2>
            <div id="tools-browser-sessions" class="space-y-2">
              <div
                :for={session <- @browser_sessions}
                id={"tools-browser-session-#{session.id}"}
                class="rounded-lg border border-zinc-200 bg-white p-4"
              >
                <p class="text-sm font-semibold text-zinc-950">
                  session {session.id} / {session.status}
                </p>
                <p class="mt-1 break-all text-xs text-zinc-500">
                  {session.current_url || "no current url"}
                </p>
                <p class="mt-1 text-xs text-zinc-500">
                  artifacts {length(session.artifacts || [])} / expires {session.expires_at || "n/a"}
                </p>
                <p :if={map_size(session.last_error || %{}) > 0} class="mt-1 text-xs text-red-700">
                  {inspect(session.last_error)}
                </p>
              </div>
              <p
                :if={@browser_sessions == []}
                class="rounded-lg border border-zinc-200 bg-white p-4 text-sm text-zinc-500"
              >
                No browser sessions recorded.
              </p>
            </div>
          </section>
        </div>

        <section class="space-y-3">
          <h2 class="text-lg font-semibold text-zinc-950">Protocol Status</h2>
          <div id="tools-protocol-status" class="grid gap-3 md:grid-cols-2">
            <div class="rounded-lg border border-zinc-200 bg-white p-4">
              <p class="text-sm font-semibold text-zinc-950">MCP Status</p>
              <p
                :for={{status, count} <- protocol_status_counts(@mcp_servers)}
                class="mt-2 text-sm text-zinc-600"
              >
                {status} {count}
              </p>
              <p :if={@mcp_servers == []} class="mt-2 text-sm text-zinc-600">none</p>
            </div>
            <div class="rounded-lg border border-zinc-200 bg-white p-4">
              <p class="text-sm font-semibold text-zinc-950">Webhook Status</p>
              <p
                :for={{status, count} <- protocol_status_counts(@webhooks)}
                class="mt-2 text-sm text-zinc-600"
              >
                {status} {count}
              </p>
              <p :if={@webhooks == []} class="mt-2 text-sm text-zinc-600">none</p>
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
