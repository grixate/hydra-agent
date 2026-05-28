defmodule HydraAgentWeb.ConnectorController do
  use HydraAgentWeb, :controller

  alias HydraAgent.{Connectors, Secrets}

  def specs(conn, _params) do
    json(conn, %{
      data: Connectors.provider_specs(),
      permission_presets: Connectors.permission_presets()
    })
  end

  def index(conn, %{"workspace_id" => workspace_id} = params) do
    accounts = Connectors.list_accounts(workspace_id, filters(params))
    json(conn, %{data: Enum.map(accounts, &account_json/1)})
  end

  def create(conn, %{"workspace_id" => workspace_id} = params) do
    case Connectors.create_account(Map.put(params, "workspace_id", workspace_id)) do
      {:ok, account} ->
        conn |> put_status(:created) |> json(%{data: account_json(account)})

      {:error, changeset} ->
        changeset_error(conn, changeset)
    end
  end

  def health(conn, %{"workspace_id" => workspace_id, "id" => id}) do
    account = Connectors.get_account_for_workspace!(workspace_id, id)

    case Connectors.health_check(account) do
      {:ok, account} -> json(conn, %{data: account_json(account)})
      {:error, changeset} -> changeset_error(conn, changeset)
    end
  end

  def grant_agent(conn, %{"workspace_id" => workspace_id, "id" => id} = params) do
    account = Connectors.get_account_for_workspace!(workspace_id, id)

    case Connectors.grant_agent_permission(account, Map.put(params, "granted_by", "api")) do
      {:ok, account} ->
        json(conn, %{data: account_json(account)})

      {:error, %Ecto.Changeset{} = changeset} ->
        changeset_error(conn, changeset)

      {:error, error} ->
        conn |> put_status(:unprocessable_entity) |> json(%{errors: error})
    end
  end

  def actions(conn, %{"workspace_id" => workspace_id} = params) do
    actions = Connectors.list_actions(workspace_id, filters(params))
    json(conn, %{data: Enum.map(actions, &action_json/1)})
  end

  def request_action(conn, %{"workspace_id" => workspace_id, "account_id" => account_id} = params) do
    account = Connectors.get_account_for_workspace!(workspace_id, account_id)

    case Connectors.request_action(account, params) do
      {:ok, action} ->
        conn |> put_status(:created) |> json(%{data: action_json(action)})

      {:error, %Ecto.Changeset{} = changeset} ->
        changeset_error(conn, changeset)

      {:error, error} ->
        conn |> put_status(:unprocessable_entity) |> json(%{errors: error})
    end
  end

  def approve_action(conn, %{"workspace_id" => workspace_id, "action_id" => action_id} = params) do
    action = Connectors.get_action_for_workspace!(workspace_id, action_id)

    case Connectors.approve_action(action, params) do
      {:ok, action} -> json(conn, %{data: action_json(action)})
      {:error, error} -> conn |> put_status(:unprocessable_entity) |> json(%{errors: error})
    end
  end

  def reject_action(conn, %{"workspace_id" => workspace_id, "action_id" => action_id} = params) do
    action = Connectors.get_action_for_workspace!(workspace_id, action_id)

    case Connectors.reject_action(action, params) do
      {:ok, action} -> json(conn, %{data: action_json(action)})
      {:error, error} -> conn |> put_status(:unprocessable_entity) |> json(%{errors: error})
    end
  end

  defp account_json(account) do
    %{
      id: account.id,
      workspace_id: account.workspace_id,
      provider: account.provider,
      slug: account.slug,
      display_name: account.display_name,
      status: account.status,
      credential_ref: Secrets.safe_ref(account.credential_env),
      refresh_ref: Secrets.safe_ref(account.refresh_env),
      config: account.config,
      capabilities: account.capabilities,
      readiness: Connectors.setup_readiness(account),
      setup_guide: Connectors.provider_setup_guide(account.provider),
      permission_grants: Connectors.agent_permission_grants(account),
      last_health: account.last_health,
      last_error: account.last_error,
      metadata: account.metadata,
      inserted_at: account.inserted_at,
      updated_at: account.updated_at
    }
  end

  defp action_json(action) do
    %{
      id: action.id,
      workspace_id: action.workspace_id,
      connector_account_id: action.connector_account_id,
      agent_id: action.agent_id,
      automation_id: action.automation_id,
      provider: action.provider,
      action: action.action,
      side_effect_class: action.side_effect_class,
      status: action.status,
      input: action.input,
      result: action.result,
      last_error: action.last_error,
      requested_by: action.requested_by,
      approved_by: action.approved_by,
      approved_at: action.approved_at,
      executed_at: action.executed_at,
      metadata: action.metadata,
      inserted_at: action.inserted_at,
      updated_at: action.updated_at
    }
  end

  defp filters(params) do
    params
    |> Map.take(["provider", "status", "limit"])
    |> Map.new(fn {key, value} -> {key, parse_limit(key, value)} end)
    |> Enum.reject(fn {_key, value} -> value in [nil, ""] end)
    |> Map.new()
  end

  defp parse_limit("limit", value) when is_binary(value) do
    case Integer.parse(value) do
      {limit, ""} when limit > 0 -> min(limit, 1_000)
      _other -> nil
    end
  end

  defp parse_limit(_key, value), do: value

  defp changeset_error(conn, changeset) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{errors: errors_json(changeset)})
  end

  defp errors_json(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
      Enum.reduce(opts, message, fn {key, value}, acc ->
        String.replace(acc, "%{#{key}}", to_string(value))
      end)
    end)
  end
end
