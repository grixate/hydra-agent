defmodule HydraAgent.Runtime.Authorizer do
  @moduledoc """
  Least-privilege authorization for tool execution.

  Authorization is a pure decision layer: it returns `:authorized`,
  `:approval_required`, or `:blocked` with the reason that should be audited.
  """

  import Ecto.Query

  alias HydraAgent.Repo
  alias HydraAgent.MCP
  alias HydraAgent.Runtime.{AgentProfile, ToolPolicy}
  alias HydraAgent.Tools.Registry

  @dangerous_side_effects ~w(workspace_write shell network browser mcp external_delivery plugin_install media_generation code_execution multi_model)

  def authorize(agent, tool_name, opts \\ [])

  def authorize(%AgentProfile{} = agent, tool_name, opts) do
    with {_, tool_spec} <- find_tool(tool_name),
         :ok <- tool_allowed_by_capabilities(agent, tool_spec),
         :ok <- side_effect_allowed_by_capabilities(agent, tool_spec),
         {:ok, policy} <- find_policy(agent, opts),
         :ok <- tool_allowed_by_policy(policy, tool_spec),
         :ok <- side_effect_allowed_by_policy(policy, tool_spec),
         :ok <- input_allowed_by_policy(policy, tool_spec, Keyword.get(opts, :input, %{})) do
      decision(agent, tool_spec, policy, opts)
    else
      {:blocked, reason, metadata} ->
        {:blocked, decision_payload(agent, tool_name, reason, metadata)}
    end
  end

  def authorize(_, tool_name, _opts) do
    {:blocked, %{"tool_name" => tool_name, "reason" => "missing_agent"}}
  end

  defp find_tool(tool_name) do
    case Registry.get(tool_name) do
      nil -> {:blocked, "unknown_tool", %{"tool_name" => tool_name}}
      tool -> tool
    end
  end

  defp tool_allowed_by_capabilities(agent, tool_spec) do
    tools = get_in(agent.capability_profile || %{}, ["tools"]) || []

    if tool_spec.name in tools do
      :ok
    else
      {:blocked, "tool_not_in_agent_capabilities", %{"allowed_tools" => tools}}
    end
  end

  defp side_effect_allowed_by_capabilities(agent, tool_spec) do
    classes = get_in(agent.capability_profile || %{}, ["side_effect_classes"]) || ["read_only"]

    if tool_spec.side_effect_class in classes do
      :ok
    else
      {:blocked, "side_effect_not_in_agent_capabilities",
       %{"allowed_side_effect_classes" => classes}}
    end
  end

  defp find_policy(agent, opts) do
    policy =
      ToolPolicy
      |> where([policy], policy.workspace_id == ^agent.workspace_id)
      |> where([policy], is_nil(policy.agent_id) or policy.agent_id == ^agent.id)
      |> order_by([policy],
        desc: fragment("? IS NOT NULL", policy.agent_id),
        desc: policy.inserted_at
      )
      |> limit(1)
      |> Repo.one()

    cond do
      policy ->
        {:ok, policy}

      capability_policy_fallback?(opts) ->
        {:ok,
         %ToolPolicy{
           workspace_id: agent.workspace_id,
           allowed_tools: get_in(agent.capability_profile || %{}, ["tools"]) || [],
           side_effect_classes:
             get_in(agent.capability_profile || %{}, ["side_effect_classes"]) || ["read_only"],
           requires_approval: true
         }}

      true ->
        {:blocked, "missing_tool_policy", %{}}
    end
  end

  defp capability_policy_fallback?(opts) do
    Keyword.get(
      opts,
      :allow_capability_fallback,
      Application.get_env(:hydra_agent, :allow_capability_policy_fallback, true)
    )
  end

  defp tool_allowed_by_policy(policy, tool_spec) do
    if tool_spec.name in (policy.allowed_tools || []) do
      :ok
    else
      {:blocked, "tool_not_allowed_by_policy",
       %{"policy_allowed_tools" => policy.allowed_tools || []}}
    end
  end

  defp side_effect_allowed_by_policy(policy, tool_spec) do
    if tool_spec.side_effect_class in (policy.side_effect_classes || []) do
      :ok
    else
      {:blocked, "side_effect_not_allowed_by_policy",
       %{"policy_side_effect_classes" => policy.side_effect_classes || []}}
    end
  end

  defp input_allowed_by_policy(policy, %{side_effect_class: "network"}, input) do
    input = stringify_keys(input || %{})
    allowlist = policy.network_allowlist || []

    case URI.parse(input["url"] || "") do
      %URI{host: host, scheme: scheme} when scheme in ["http", "https"] and is_binary(host) ->
        if host_allowed?(host, allowlist) do
          :ok
        else
          {:blocked, "network_host_not_allowed",
           %{"host" => host, "network_allowlist" => allowlist}}
        end

      _uri ->
        {:blocked, "network_url_invalid", %{"url" => input["url"]}}
    end
  end

  defp input_allowed_by_policy(policy, %{side_effect_class: "browser"}, input) do
    input = stringify_keys(input || %{})

    case input["url"] do
      nil ->
        :ok

      url ->
        input_allowed_by_policy(policy, %{side_effect_class: "network"}, %{"url" => url})
    end
  end

  defp input_allowed_by_policy(policy, %{side_effect_class: "shell"}, input) do
    input = stringify_keys(input || %{})
    allowlist = policy.shell_allowlist || []

    case input["command"] do
      command when is_list(command) ->
        command = Enum.map(command, &to_string/1)

        with :ok <- shell_command_allowed(command, allowlist),
             :ok <- shell_env_allowed(policy, input["env"] || %{}) do
          :ok
        end

      _command ->
        {:blocked, "shell_command_invalid", %{"command" => input["command"]}}
    end
  end

  defp input_allowed_by_policy(policy, %{name: tool_name}, input)
       when tool_name in ["file_list", "file_read", "file_write"] do
    input = stringify_keys(input || %{})
    path = input["path"] || "."

    if filesystem_path_allowed?(
         path,
         policy.filesystem_allowlist || [],
         policy.filesystem_denylist || []
       ) do
      :ok
    else
      {:blocked, "filesystem_path_not_allowed",
       %{
         "path" => path,
         "filesystem_allowlist" => policy.filesystem_allowlist || [],
         "filesystem_denylist" => policy.filesystem_denylist || []
       }}
    end
  end

  defp input_allowed_by_policy(policy, %{name: "mcp_call"}, input) do
    case MCP.authorize_call(policy.workspace_id, input) do
      :ok -> :ok
      {:blocked, reason, metadata} -> {:blocked, reason, metadata}
    end
  end

  defp input_allowed_by_policy(_policy, _tool_spec, _input), do: :ok

  defp host_allowed?(_host, ["*" | _allowlist]), do: true

  defp host_allowed?(host, allowlist) do
    Enum.any?(allowlist, fn allowed ->
      allowed = String.downcase(allowed)
      host = String.downcase(host)

      cond do
        allowed == host ->
          true

        String.starts_with?(allowed, ".") ->
          String.ends_with?(host, allowed)

        String.starts_with?(allowed, "*.") ->
          String.ends_with?(host, String.trim_leading(allowed, "*"))

        true ->
          false
      end
    end)
  end

  defp shell_command_allowed(_command, ["*" | _allowlist]), do: :ok

  defp shell_command_allowed(command, allowlist) do
    command_string = Enum.join(command, " ")

    allowed? =
      Enum.any?(allowlist, fn allowed ->
        allowed = to_string(allowed)
        allowed_parts = String.split(allowed)

        cond do
          allowed == command_string ->
            true

          allowed_parts == [] ->
            false

          Enum.take(command, length(allowed_parts)) == allowed_parts ->
            true

          true ->
            false
        end
      end)

    if allowed? do
      :ok
    else
      {:blocked, "shell_command_not_allowed",
       %{"command" => command, "shell_allowlist" => allowlist}}
    end
  end

  defp shell_env_allowed(policy, env) when is_map(env) do
    allowlist = policy.shell_env_allowlist || []
    env_keys = env |> Map.keys() |> Enum.map(&to_string/1)
    disallowed = env_keys -- allowlist

    cond do
      env_keys == [] ->
        :ok

      "*" in allowlist ->
        :ok

      disallowed == [] ->
        :ok

      true ->
        {:blocked, "shell_env_not_allowed",
         %{"env" => disallowed, "shell_env_allowlist" => allowlist}}
    end
  end

  defp shell_env_allowed(policy, _env) do
    {:blocked, "shell_env_invalid", %{"shell_env_allowlist" => policy.shell_env_allowlist || []}}
  end

  defp filesystem_path_allowed?(path, ["*" | _allowlist], denylist) do
    not filesystem_path_denied?(path, denylist)
  end

  defp filesystem_path_allowed?(path, allowlist, denylist) do
    normalized = normalize_relative_path(path)

    allowed? =
      Enum.any?(allowlist, fn allowed ->
        allowed = normalize_relative_path(allowed)
        normalized == allowed or String.starts_with?(normalized, allowed <> "/")
      end)

    allowed? and not filesystem_path_denied?(normalized, denylist)
  end

  defp filesystem_path_denied?(path, denylist) do
    normalized = normalize_relative_path(path)

    Enum.any?(denylist, fn denied ->
      denied = normalize_relative_path(denied)
      normalized == denied or String.starts_with?(normalized, denied <> "/")
    end)
  end

  defp normalize_relative_path(path) do
    path
    |> to_string()
    |> Path.expand("/")
    |> Path.relative_to("/")
  end

  defp decision(agent, tool_spec, policy, opts) do
    autonomy_level = Keyword.get(opts, :autonomy_level) || "recommend"

    approval_mode =
      get_in(agent.capability_profile || %{}, ["approval_policy", "mode"]) ||
        "required_for_sensitive"

    requires_approval? =
      policy.requires_approval ||
        requires_sensitive_approval?(tool_spec, autonomy_level, approval_mode)

    payload =
      decision_payload(agent, tool_spec.name, "authorized", %{
        "side_effect_class" => tool_spec.side_effect_class,
        "approval_sensitive" => Map.get(tool_spec, :approval_sensitive, true),
        "timeout_ms" => Map.get(tool_spec, :timeout_ms),
        "autonomy_level" => autonomy_level,
        "approval_mode" => approval_mode,
        "shell_env_allowlist" => policy.shell_env_allowlist || []
      })

    if requires_approval? and tool_spec.side_effect_class in @dangerous_side_effects do
      {:approval_required, Map.put(payload, "reason", "approval_required")}
    else
      {:authorized, payload}
    end
  end

  defp requires_sensitive_approval?(_tool_spec, "fully_automatic", "never"), do: false
  defp requires_sensitive_approval?(_tool_spec, "execute_with_approval", _approval_mode), do: true
  defp requires_sensitive_approval?(_tool_spec, "execute_with_review", _approval_mode), do: false
  defp requires_sensitive_approval?(_tool_spec, _autonomy_level, "always"), do: true
  defp requires_sensitive_approval?(_tool_spec, _autonomy_level, _approval_mode), do: false

  defp decision_payload(%AgentProfile{} = agent, tool_name, reason, metadata) do
    %{
      "agent_id" => agent.id,
      "workspace_id" => agent.workspace_id,
      "tool_name" => tool_name,
      "reason" => reason,
      "metadata" => metadata
    }
  end

  defp stringify_keys(map) when is_map(map) do
    Map.new(map, fn {key, value} -> {to_string(key), value} end)
  end
end
