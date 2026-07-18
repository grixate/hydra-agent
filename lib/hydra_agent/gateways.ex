defmodule HydraAgent.Gateways do
  @moduledoc """
  External gateway definitions and dispatch.
  """

  import Ecto.Query

  alias HydraAgent.{AgentChat, Repo, Runtime}
  alias HydraAgent.Gateways.{WebhookEndpoint, WebhookIdempotencyClaim}

  @webhook_acceptance_status 200

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

  def list_webhook_idempotency_claims(workspace_id) do
    WebhookIdempotencyClaim
    |> where([claim], claim.workspace_id == ^workspace_id)
    |> order_by([claim], desc: claim.inserted_at)
    |> Repo.all()
  end

  def get_webhook_idempotency_claim(endpoint_id, idempotency_key) do
    WebhookIdempotencyClaim
    |> where(
      [claim],
      claim.webhook_endpoint_id == ^endpoint_id and
        claim.idempotency_key == ^idempotency_key
    )
    |> Repo.one()
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

  def dispatch(%WebhookEndpoint{target_type: "run_create"}, _payload),
    do: {:error, %{"reason" => "idempotency_key_required"}}

  @doc """
  Creates a run exactly once for an endpoint-scoped idempotency key.

  The claim, run, endpoint receipt, and stored response commit in one database
  transaction. A concurrent insert for the same endpoint and key waits for that
  transaction, then replays its response instead of creating another run.
  """
  def dispatch_idempotent_run(
        %WebhookEndpoint{target_type: "run_create"} = endpoint,
        payload,
        idempotency_key
      ) do
    request_sha256 = request_sha256(payload)
    timestamp = now()

    transaction_result =
      Repo.transaction(fn ->
        attrs = %{
          workspace_id: endpoint.workspace_id,
          webhook_endpoint_id: endpoint.id,
          idempotency_key: idempotency_key,
          request_sha256: request_sha256,
          status: "processing",
          inserted_at: timestamp,
          updated_at: timestamp
        }

        case Repo.insert_all(WebhookIdempotencyClaim, [attrs],
               on_conflict: :nothing,
               conflict_target: [:webhook_endpoint_id, :idempotency_key],
               returning: [:id]
             ) do
          {1, [%{id: claim_id}]} ->
            accept_idempotent_run(endpoint, payload, claim_id)

          {0, []} ->
            replay_idempotent_run(endpoint, idempotency_key, request_sha256)
        end
      end)

    case transaction_result do
      {:ok, {:accepted, response_body, response_status}} ->
        {:ok, response_body, response_status, false}

      {:ok, {:replayed, response_body, response_status}} ->
        {:ok, response_body, response_status, true}

      {:error, {:dispatch_failed, error}} ->
        _ = mark_error(endpoint, normalize_error(error))
        {:error, error}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp accept_idempotent_run(endpoint, payload, claim_id) do
    with {:ok, run} <- create_webhook_run(endpoint, payload),
         {:ok, updated_endpoint} <- mark_received(endpoint, %{"last_run_id" => run.id}) do
      response_body = acceptance_response(updated_endpoint, run)
      completed_at = now()

      claim_id
      |> then(&Repo.get!(WebhookIdempotencyClaim, &1))
      |> WebhookIdempotencyClaim.changeset(%{
        run_id: run.id,
        status: "completed",
        response_status: @webhook_acceptance_status,
        response_body: response_body,
        completed_at: completed_at
      })
      |> Repo.update!()

      {:accepted, response_body, @webhook_acceptance_status}
    else
      {:error, error} -> Repo.rollback({:dispatch_failed, error})
    end
  end

  defp replay_idempotent_run(endpoint, idempotency_key, request_sha256) do
    claim =
      WebhookIdempotencyClaim
      |> where(
        [claim],
        claim.webhook_endpoint_id == ^endpoint.id and
          claim.idempotency_key == ^idempotency_key
      )
      |> lock("FOR UPDATE")
      |> Repo.one!()

    cond do
      claim.request_sha256 != request_sha256 ->
        Repo.rollback(:idempotency_conflict)

      claim.status != "completed" or is_nil(claim.response_body) or
          is_nil(claim.response_status) ->
        Repo.rollback(:idempotency_request_in_progress)

      true ->
        {:replayed, claim.response_body, claim.response_status}
    end
  end

  defp create_webhook_run(endpoint, payload) do
    endpoint = Repo.preload(endpoint, [:agent])

    Runtime.create_run(%{
      workspace_id: endpoint.workspace_id,
      supervisor_agent_id: endpoint.agent_id,
      title: payload["title"] || endpoint.config["title"] || "Webhook run: #{endpoint.name}",
      goal: payload["goal"] || payload["content"] || Jason.encode!(payload),
      autonomy_level: endpoint.config["autonomy_level"] || "recommend",
      metadata: %{"webhook_endpoint_id" => endpoint.id, "payload" => payload}
    })
  end

  defp acceptance_response(endpoint, run) do
    %{
      "data" => %{
        "id" => endpoint.id,
        "workspace_id" => endpoint.workspace_id,
        "agent_id" => endpoint.agent_id,
        "webhook_endpoint_id" => endpoint.id,
        "run_id" => run.id,
        "status" => "accepted",
        "target_type" => endpoint.target_type
      }
    }
  end

  defp request_sha256(payload) do
    payload
    |> canonical_term()
    |> :erlang.term_to_binary()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp canonical_term(value) when is_map(value) do
    entries =
      value
      |> Enum.map(fn {key, nested_value} -> {to_string(key), canonical_term(nested_value)} end)
      |> Enum.sort_by(&elem(&1, 0))

    {:map, entries}
  end

  defp canonical_term(value) when is_list(value), do: {:list, Enum.map(value, &canonical_term/1)}
  defp canonical_term(value), do: {:value, value}

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

  defp normalize_error(%{__struct__: module}),
    do: %{"reason" => module |> Module.split() |> List.last() |> Macro.underscore()}

  defp normalize_error(error) when is_map(error) do
    normalized =
      Enum.reduce(["reason", "code", "status"], %{}, fn key, acc ->
        value = Map.get(error, key) || Map.get(error, String.to_existing_atom(key))

        if is_binary(value) or is_number(value) or is_atom(value),
          do: Map.put(acc, key, to_string(value)),
          else: acc
      end)

    if normalized == %{}, do: %{"reason" => "dispatch_failed"}, else: normalized
  end

  defp normalize_error({reason, _detail}) when is_atom(reason),
    do: %{"reason" => Atom.to_string(reason)}

  defp normalize_error(error) when is_atom(error), do: %{"reason" => Atom.to_string(error)}
  defp normalize_error(_error), do: %{"reason" => "dispatch_failed"}

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
