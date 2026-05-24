defmodule HydraAgent.Gateways do
  @moduledoc """
  External gateway definitions and dispatch.
  """

  import Ecto.Query

  alias HydraAgent.{AgentChat, Repo, Runtime}
  alias HydraAgent.Gateways.WebhookEndpoint

  def list_webhooks(workspace_id) do
    WebhookEndpoint
    |> where([endpoint], endpoint.workspace_id == ^workspace_id)
    |> order_by([endpoint], asc: endpoint.name)
    |> Repo.all()
  end

  def get_webhook!(id), do: Repo.get!(WebhookEndpoint, id)

  def get_active_webhook_by_slug(slug) do
    WebhookEndpoint
    |> where([endpoint], endpoint.slug == ^slug and endpoint.status == "active")
    |> preload([:agent])
    |> Repo.one()
  end

  def create_webhook(attrs) do
    %WebhookEndpoint{} |> WebhookEndpoint.changeset(stringify_keys(attrs)) |> Repo.insert()
  end

  def dispatch(%WebhookEndpoint{target_type: "agent_chat"} = endpoint, payload) do
    endpoint = Repo.preload(endpoint, [:agent])
    content = payload["content"] || payload["text"] || Jason.encode!(payload)

    with {:ok, conversation} <-
           AgentChat.start_conversation(endpoint.agent, %{
             title: endpoint.config["title"] || "Webhook: #{endpoint.name}",
             channel: "webhook",
             metadata: %{"webhook_endpoint_id" => endpoint.id}
           }),
         {:ok, response} <- AgentChat.respond(conversation, content, source: "webhook") do
      mark_received(endpoint, %{
        "last_conversation_id" => response.conversation.id,
        "last_assistant_turn_id" => response.assistant_turn.id
      })
    else
      {:error, error} -> mark_error(endpoint, normalize_error(error))
    end
  end

  def dispatch(%WebhookEndpoint{target_type: "run_create"} = endpoint, payload) do
    endpoint = Repo.preload(endpoint, [:agent])

    attrs = %{
      workspace_id: endpoint.workspace_id,
      supervisor_agent_id: endpoint.agent_id,
      title: payload["title"] || endpoint.config["title"] || "Webhook run: #{endpoint.name}",
      goal: payload["goal"] || payload["content"] || Jason.encode!(payload),
      autonomy_level: endpoint.config["autonomy_level"] || "recommend",
      metadata: %{"webhook_endpoint_id" => endpoint.id, "payload" => payload}
    }

    case Runtime.create_run(attrs) do
      {:ok, run} -> mark_received(endpoint, %{"last_run_id" => run.id})
      {:error, error} -> mark_error(endpoint, normalize_error(error))
    end
  end

  defp mark_received(endpoint, metadata) do
    endpoint
    |> WebhookEndpoint.changeset(%{
      last_received_at: now(),
      last_error: %{},
      metadata: Map.merge(endpoint.metadata || %{}, metadata)
    })
    |> Repo.update()
  end

  defp mark_error(endpoint, error) do
    endpoint
    |> WebhookEndpoint.changeset(%{last_received_at: now(), last_error: error})
    |> Repo.update()
  end

  defp normalize_error(%Ecto.Changeset{} = changeset),
    do: %{"reason" => "changeset_error", "errors" => changeset_errors(changeset)}

  defp normalize_error(error) when is_map(error), do: error
  defp normalize_error(error), do: %{"reason" => inspect(error)}

  defp changeset_errors(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
      Enum.reduce(opts, message, fn {key, value}, acc ->
        String.replace(acc, "%{#{key}}", to_string(value))
      end)
    end)
  end

  defp stringify_keys(map) when is_map(map),
    do: Map.new(map, fn {key, value} -> {to_string(key), value} end)

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:microsecond)
end
