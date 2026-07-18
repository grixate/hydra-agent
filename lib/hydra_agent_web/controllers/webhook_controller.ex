defmodule HydraAgentWeb.WebhookController do
  use HydraAgentWeb, :controller

  alias HydraAgent.{Gateways, Secrets}

  @idempotency_key_pattern ~r/^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$/

  plug HydraAgentWeb.Plugs.RateLimit,
       [scope: "incoming_webhook", limit: 60, window_seconds: 60, identity: :webhook]
       when action in [:receive]

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
        case Secrets.verify_bearer(conn, webhook.token_env) do
          :ok ->
            receive_authenticated(conn, webhook, Map.drop(params, ["slug"]))

          {:error, error} when is_map(error) ->
            conn |> put_status(:unauthorized) |> json(%{errors: error})
        end
    end
  end

  defp receive_authenticated(conn, %{target_type: "run_create"} = webhook, payload) do
    with {:ok, idempotency_key} <- idempotency_key(conn),
         {:ok, response_body, response_status, replayed?} <-
           Gateways.dispatch_idempotent_run(webhook, payload, idempotency_key) do
      conn
      |> put_resp_header("idempotency-replayed", to_string(replayed?))
      |> put_status(response_status)
      |> json(response_body)
    else
      {:error, :idempotency_key_required} ->
        idempotency_error(
          conn,
          :bad_request,
          "idempotency_key_required",
          "Idempotency-Key header is required"
        )

      {:error, :invalid_idempotency_key} ->
        idempotency_error(
          conn,
          :bad_request,
          "invalid_idempotency_key",
          "Idempotency-Key must be 1–128 ASCII letters, numbers, dots, underscores, colons, or hyphens"
        )

      {:error, :idempotency_conflict} ->
        idempotency_error(
          conn,
          :conflict,
          "idempotency_conflict",
          "Idempotency-Key was already used with a different request"
        )

      {:error, :idempotency_request_in_progress} ->
        idempotency_error(
          conn,
          :conflict,
          "idempotency_request_in_progress",
          "A request with this Idempotency-Key is still being processed"
        )

      {:error, %Ecto.Changeset{} = changeset} ->
        conn |> put_status(:unprocessable_entity) |> json(%{errors: errors_json(changeset)})

      {:error, _error} ->
        conn
        |> put_status(:internal_server_error)
        |> json(%{errors: %{detail: "Webhook dispatch failed"}})
    end
  end

  defp receive_authenticated(conn, webhook, payload) do
    case Gateways.dispatch(webhook, payload) do
      {:ok, updated_webhook} ->
        json(conn, %{data: webhook_json(updated_webhook)})

      {:error, %Ecto.Changeset{} = changeset} ->
        conn |> put_status(:unprocessable_entity) |> json(%{errors: errors_json(changeset)})

      {:error, _error} ->
        conn
        |> put_status(:internal_server_error)
        |> json(%{errors: %{detail: "Webhook dispatch failed"}})
    end
  end

  defp idempotency_key(conn) do
    case get_req_header(conn, "idempotency-key") do
      [] ->
        {:error, :idempotency_key_required}

      [key]
      when is_binary(key) and byte_size(key) >= 1 and byte_size(key) <= 128 ->
        if String.valid?(key) and Regex.match?(@idempotency_key_pattern, key),
          do: {:ok, key},
          else: {:error, :invalid_idempotency_key}

      _other ->
        {:error, :invalid_idempotency_key}
    end
  end

  defp idempotency_error(conn, status, code, detail) do
    conn
    |> put_status(status)
    |> json(%{errors: %{code: code, detail: detail}})
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
