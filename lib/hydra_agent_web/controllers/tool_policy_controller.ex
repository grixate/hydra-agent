defmodule HydraAgentWeb.ToolPolicyController do
  use HydraAgentWeb, :controller

  alias HydraAgent.Runtime

  def index(conn, %{"workspace_id" => workspace_id}) do
    policies = Runtime.list_tool_policies(workspace_id)
    json(conn, %{data: Enum.map(policies, &policy_json/1)})
  end

  def show(conn, %{"workspace_id" => workspace_id, "id" => id}) do
    policy = Runtime.get_tool_policy_for_workspace!(workspace_id, id)
    json(conn, %{data: policy_json(policy)})
  end

  def show(conn, %{"id" => id}) do
    policy = Runtime.get_tool_policy!(id)
    json(conn, %{data: policy_json(policy)})
  end

  def create(conn, %{"workspace_id" => workspace_id} = params) do
    create_policy(conn, Map.put(params, "workspace_id", workspace_id))
  end

  def create(conn, params) do
    create_policy(conn, params)
  end

  defp create_policy(conn, params) do
    case Runtime.create_tool_policy(params) do
      {:ok, policy} ->
        conn
        |> put_status(:created)
        |> json(%{data: policy_json(policy)})

      {:error, changeset} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{errors: errors_json(changeset)})
    end
  end

  defp policy_json(policy) do
    %{
      id: policy.id,
      workspace_id: policy.workspace_id,
      agent_id: policy.agent_id,
      scope: policy.scope,
      allowed_tools: policy.allowed_tools,
      side_effect_classes: policy.side_effect_classes,
      network_allowlist: policy.network_allowlist,
      shell_allowlist: policy.shell_allowlist,
      shell_env_allowlist: policy.shell_env_allowlist,
      filesystem_allowlist: policy.filesystem_allowlist,
      filesystem_denylist: policy.filesystem_denylist,
      requires_approval: policy.requires_approval,
      tool_bundles: get_in(policy.metadata || %{}, ["tool_bundles"]) || [],
      warnings: policy_warnings(policy),
      metadata: policy.metadata
    }
  end

  defp policy_warnings(policy) do
    side_effect_classes = policy.side_effect_classes || []
    dangerous_classes = side_effect_classes -- ["read_only"]

    []
    |> maybe_add_warning(
      dangerous_classes != [] and policy.requires_approval == false,
      "dangerous side effects can run without approval"
    )
    |> maybe_add_warning(
      "*" in (policy.network_allowlist || []),
      "network allowlist permits every host"
    )
    |> maybe_add_warning(
      "*" in (policy.shell_allowlist || []),
      "shell allowlist permits every command"
    )
    |> maybe_add_warning(
      "*" in (policy.filesystem_allowlist || []),
      "filesystem allowlist permits every path"
    )
  end

  defp maybe_add_warning(warnings, true, warning), do: warnings ++ [warning]
  defp maybe_add_warning(warnings, _condition, _warning), do: warnings

  defp errors_json(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
      Enum.reduce(opts, message, fn {key, value}, acc ->
        String.replace(acc, "%{#{key}}", to_string(value))
      end)
    end)
  end
end
