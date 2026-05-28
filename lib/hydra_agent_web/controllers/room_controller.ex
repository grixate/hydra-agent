defmodule HydraAgentWeb.RoomController do
  use HydraAgentWeb, :controller

  alias HydraAgent.{Rooms, Secrets}

  def index(conn, %{"workspace_id" => workspace_id}) do
    rooms = Rooms.list_rooms(workspace_id)
    json(conn, %{data: Enum.map(rooms, &room_json/1)})
  end

  def create(conn, %{"workspace_id" => workspace_id} = params) do
    case Rooms.create_room(Map.put(params, "workspace_id", workspace_id)) do
      {:ok, room} ->
        conn |> put_status(:created) |> json(%{data: room_json(room)})

      {:error, changeset} ->
        changeset_error(conn, changeset)
    end
  end

  def show(conn, %{"workspace_id" => workspace_id, "id" => id}) do
    room = Rooms.get_room_for_workspace!(workspace_id, id)
    json(conn, %{data: room_json(room, include_messages: true)})
  end

  def update(conn, %{"workspace_id" => workspace_id, "id" => id} = params) do
    room = Rooms.get_room_for_workspace!(workspace_id, id)

    case Rooms.update_room(room, params) do
      {:ok, room} -> json(conn, %{data: room_json(room)})
      {:error, changeset} -> changeset_error(conn, changeset)
    end
  end

  def create_member(conn, %{"workspace_id" => workspace_id, "id" => id} = params) do
    room = Rooms.get_room_for_workspace!(workspace_id, id)

    case Rooms.create_member(room, params) do
      {:ok, member} ->
        conn |> put_status(:created) |> json(%{data: member_json(member)})

      {:error, changeset} ->
        changeset_error(conn, changeset)
    end
  end

  def delete_member(conn, %{"workspace_id" => workspace_id, "id" => id, "agent_id" => agent_id}) do
    room = Rooms.get_room_for_workspace!(workspace_id, id)

    case Rooms.delete_member(room, agent_id) do
      {:ok, _member} ->
        json(conn, %{data: %{deleted: true}})

      {:error, :not_found} ->
        conn |> put_status(:not_found) |> json(%{errors: %{detail: "Not found"}})
    end
  end

  def messages(conn, %{"workspace_id" => workspace_id, "id" => id} = params) do
    room = Rooms.get_room_for_workspace!(workspace_id, id)

    json(conn, %{
      data: Enum.map(Rooms.list_messages(room, message_filters(params)), &message_json/1)
    })
  end

  def send_message(conn, %{"workspace_id" => workspace_id, "id" => id, "content" => content}) do
    room = Rooms.get_room_for_workspace!(workspace_id, id)

    case Rooms.send_user_message(room, content, source_channel: "api") do
      {:ok, result} ->
        json(conn, %{data: room_result_json(result)})

      {:error, %Ecto.Changeset{} = changeset} ->
        changeset_error(conn, changeset)

      {:error, error} ->
        conn |> put_status(:unprocessable_entity) |> json(%{errors: error})
    end
  end

  def approve_proposal(
        conn,
        %{"workspace_id" => workspace_id, "id" => id, "message_id" => message_id} = params
      ) do
    room = Rooms.get_room_for_workspace!(workspace_id, id)

    opts =
      []
      |> maybe_put_opt(:agent_ids, params["agent_ids"])
      |> maybe_put_opt(:approved_by, params["approved_by"])

    case Rooms.approve_proposal(room, message_id, opts) do
      {:ok, result} ->
        json(conn, %{
          data: %{
            proposal: message_json(result.proposal),
            agent_messages: Enum.map(result.agent_messages, &message_json/1)
          }
        })

      {:error, error} ->
        conn |> put_status(:unprocessable_entity) |> json(%{errors: error})
    end
  end

  def transcript(conn, %{"workspace_id" => workspace_id, "id" => id} = params) do
    room = Rooms.get_room_for_workspace!(workspace_id, id)

    json(conn, %{
      data: Rooms.export_transcript(room, Keyword.put(message_filters(params), :limit, 500))
    })
  end

  def deliveries(conn, %{"workspace_id" => workspace_id, "id" => id} = params) do
    room = Rooms.get_room_for_workspace!(workspace_id, id)

    json(conn, %{
      data: Enum.map(Rooms.list_deliveries(room, delivery_filters(params)), &delivery_json/1)
    })
  end

  def retry_delivery(conn, %{
        "workspace_id" => workspace_id,
        "id" => id,
        "delivery_id" => delivery_id
      }) do
    room = Rooms.get_room_for_workspace!(workspace_id, id)
    delivery = Rooms.get_delivery_for_room!(room, delivery_id)

    case Rooms.retry_delivery(delivery) do
      {:ok, sent} ->
        json(conn, %{data: %{sent_count: length(sent)}})

      {:error, error} ->
        conn |> put_status(:unprocessable_entity) |> json(%{errors: error})
    end
  end

  def create_channel_binding(conn, %{"workspace_id" => workspace_id, "id" => id} = params) do
    room = Rooms.get_room_for_workspace!(workspace_id, id)

    case Rooms.create_channel_binding(room, params) do
      {:ok, binding} ->
        conn |> put_status(:created) |> json(%{data: channel_binding_json(binding)})

      {:error, changeset} ->
        changeset_error(conn, changeset)
    end
  end

  def channel_bindings(conn, %{"workspace_id" => workspace_id, "id" => id}) do
    room = Rooms.get_room_for_workspace!(workspace_id, id)
    json(conn, %{data: Enum.map(Rooms.list_channel_bindings(room), &channel_binding_json/1)})
  end

  def retry_channel_binding(conn, %{
        "workspace_id" => workspace_id,
        "id" => id,
        "binding_id" => binding_id
      }) do
    room = Rooms.get_room_for_workspace!(workspace_id, id)
    binding = Rooms.get_channel_binding_for_room!(room, binding_id)

    case Rooms.retry_channel_binding(binding) do
      {:ok, sent} ->
        json(conn, %{data: %{sent_count: length(sent)}})

      {:error, error} ->
        conn |> put_status(:unprocessable_entity) |> json(%{errors: error})
    end
  end

  defp room_json(room, opts \\ []) do
    base = %{
      id: room.id,
      workspace_id: room.workspace_id,
      coordinator_agent_id: room.coordinator_agent_id,
      title: room.title,
      slug: room.slug,
      status: room.status,
      routing_policy: room.routing_policy,
      metadata: room.metadata,
      last_message_at: room.last_message_at,
      members: Enum.map(loaded(room.members), &member_json/1),
      channel_bindings: Enum.map(loaded(room.channel_bindings), &channel_binding_json/1)
    }

    if Keyword.get(opts, :include_messages, false) do
      Map.put(base, :messages, Enum.map(loaded(room.messages), &message_json/1))
    else
      base
    end
  end

  defp room_result_json(result) do
    %{
      user_message: message_json(result.user_message),
      agent_messages: Enum.map(result.agent_messages, &message_json/1),
      pending_proposal: result.pending_proposal && message_json(result.pending_proposal)
    }
  end

  defp member_json(member) do
    %{
      id: member.id,
      workspace_id: member.workspace_id,
      room_id: member.room_id,
      agent_id: member.agent_id,
      mention_handle: member.mention_handle,
      role: member.role,
      response_mode: member.response_mode,
      priority: member.priority,
      metadata: member.metadata
    }
  end

  defp message_json(message) do
    %{
      id: message.id,
      workspace_id: message.workspace_id,
      room_id: message.room_id,
      agent_id: message.agent_id,
      conversation_id: message.conversation_id,
      turn_id: message.turn_id,
      author_type: message.author_type,
      source_channel: message.source_channel,
      external_message_id: message.external_message_id,
      content: message.content,
      metadata: message.metadata,
      deliveries: Enum.map(loaded(message.deliveries), &delivery_json/1),
      inserted_at: message.inserted_at
    }
  end

  defp delivery_json(delivery) do
    %{
      id: delivery.id,
      workspace_id: delivery.workspace_id,
      room_id: delivery.room_id,
      message_id: delivery.message_id,
      channel_binding_id: delivery.channel_binding_id,
      provider: delivery.provider,
      external_message_id: delivery.external_message_id,
      status: delivery.status,
      attempts: delivery.attempts,
      last_error: delivery.last_error,
      metadata: delivery.metadata,
      sent_at: delivery.sent_at,
      acknowledged_at: delivery.acknowledged_at,
      inserted_at: delivery.inserted_at,
      updated_at: delivery.updated_at
    }
  end

  defp channel_binding_json(binding) do
    %{
      id: binding.id,
      workspace_id: binding.workspace_id,
      room_id: binding.room_id,
      provider: binding.provider,
      slug: binding.slug,
      status: binding.status,
      external_chat_id: binding.external_chat_id,
      token_ref: Secrets.safe_ref(binding.token_env),
      secret_ref: Secrets.safe_ref(binding.secret_env),
      config: binding.config,
      last_received_at: binding.last_received_at,
      last_sent_at: binding.last_sent_at,
      last_error: binding.last_error,
      telegram_setup:
        if(binding.provider == "telegram", do: Rooms.telegram_setup_readiness(binding), else: nil),
      metadata: binding.metadata
    }
  end

  defp loaded(value), do: if(Ecto.assoc_loaded?(value), do: value, else: [])

  defp maybe_put_opt(opts, _key, nil), do: opts
  defp maybe_put_opt(opts, _key, ""), do: opts
  defp maybe_put_opt(opts, key, value), do: Keyword.put(opts, key, value)

  defp message_filters(params) do
    [
      limit: parse_limit(params["limit"], 100),
      query: params["query"] || params["q"],
      author_type: params["author_type"],
      agent_id: params["agent_id"],
      source_channel: params["source_channel"] || params["channel"],
      from: params["from"],
      to: params["to"],
      delivery_status: params["delivery_status"]
    ]
    |> Enum.reject(fn {_key, value} -> value in [nil, ""] end)
  end

  defp delivery_filters(params) do
    [
      limit: parse_limit(params["limit"], 100),
      status: params["status"],
      provider: params["provider"]
    ]
    |> Enum.reject(fn {_key, value} -> value in [nil, ""] end)
  end

  defp parse_limit(nil, default), do: default
  defp parse_limit("", default), do: default

  defp parse_limit(value, default) when is_binary(value) do
    case Integer.parse(value) do
      {limit, ""} when limit > 0 -> min(limit, 1_000)
      _other -> default
    end
  end

  defp parse_limit(value, _default) when is_integer(value) and value > 0, do: min(value, 1_000)
  defp parse_limit(_value, default), do: default

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
