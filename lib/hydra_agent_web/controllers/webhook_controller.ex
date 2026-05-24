defmodule HydraAgentWeb.WebhookController do
  use HydraAgentWeb, :controller

  alias HydraAgent.{Gateways, Secrets}

  def index(conn, %{"workspace_id" => workspace_id}) do
    webhooks = Gateways.list_webhooks(workspace_id)
    json(conn, %{data: Enum.map(webhooks, &webhook_json/1)})
  end

  def show(conn, %{"id" => id}) do
    webhook = Gateways.get_webhook!(id)
    json(conn, %{data: webhook_json(webhook)})
  end

  def create(conn, %{"workspace_id" => workspace_id} = params) do
    create_webhook(conn, Map.put(params, "workspace_id", workspace_id))
  end

  def create(conn, params) do
    create_webhook(conn, params)
  end

  def receive(conn, %{"slug" => slug} = params) do
    case Gateways.get_active_webhook_by_slug(slug) do
      nil ->
        conn |> put_status(:not_found) |> json(%{errors: %{detail: "Webhook not found"}})

      webhook ->
        with :ok <- Secrets.verify_bearer(conn, webhook.token_env),
             payload <- Map.drop(params, ["slug"]),
             {:ok, updated_webhook} <- Gateways.dispatch(webhook, payload) do
          json(conn, %{data: webhook_json(updated_webhook)})
        else
          {:error, error} when is_map(error) ->
            conn |> put_status(:unauthorized) |> json(%{errors: error})

          {:error, changeset} ->
            conn |> put_status(:unprocessable_entity) |> json(%{errors: errors_json(changeset)})
        end
    end
  end

  defp create_webhook(conn, params) do
    case Gateways.create_webhook(params) do
      {:ok, webhook} ->
        conn
        |> put_status(:created)
        |> json(%{data: webhook_json(webhook)})

      {:error, changeset} ->
        conn |> put_status(:unprocessable_entity) |> json(%{errors: errors_json(changeset)})
    end
  end

  defp webhook_json(webhook) do
    %{
      id: webhook.id,
      workspace_id: webhook.workspace_id,
      agent_id: webhook.agent_id,
      name: webhook.name,
      slug: webhook.slug,
      status: webhook.status,
      target_type: webhook.target_type,
      token_ref: Secrets.safe_ref(webhook.token_env),
      config: webhook.config,
      last_received_at: webhook.last_received_at,
      last_error: webhook.last_error,
      metadata: webhook.metadata
    }
  end

  defp errors_json(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
      Enum.reduce(opts, message, fn {key, value}, acc ->
        String.replace(acc, "%{#{key}}", to_string(value))
      end)
    end)
  end
end
