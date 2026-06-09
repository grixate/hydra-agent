defmodule HydraAgent.Rooms do
  @moduledoc """
  Shared multi-agent rooms for web and external channels.

  Rooms sit above the existing one-agent conversation model. A room has a shared
  transcript while each responding agent still gets a durable private
  conversation for memory, usage, provider routing, and audit compatibility.
  """

  import Ecto.Query

  alias Ecto.Multi
  alias HydraAgent.{AgentChat, Plugins, Repo, Runtime, Secrets}
  alias HydraAgent.Rooms.{ChannelBinding, Delivery, Member, Message, Room}

  def list_rooms(workspace_id) do
    Room
    |> where([room], room.workspace_id == ^normalize_id(workspace_id))
    |> order_by([room], desc: room.last_message_at, desc: room.updated_at)
    |> preload([:coordinator_agent, members: [:agent], channel_bindings: []])
    |> Repo.all()
  end

  def get_room!(id) do
    Room
    |> Repo.get!(id)
    |> preload_room()
  end

  def get_room_for_workspace!(workspace_id, id) do
    Room
    |> where(
      [room],
      room.workspace_id == ^normalize_id(workspace_id) and room.id == ^normalize_id(id)
    )
    |> Repo.one!()
    |> preload_room()
  end

  def create_room(attrs) do
    attrs = stringify_keys(attrs)

    Multi.new()
    |> Multi.insert(:room, Room.changeset(%Room{}, attrs))
    |> Multi.run(:coordinator_member, fn _repo, %{room: room} ->
      case room.coordinator_agent_id do
        nil ->
          {:ok, nil}

        agent_id ->
          create_member(room, %{
            "agent_id" => agent_id,
            "mention_handle" => coordinator_handle(room.workspace_id, agent_id),
            "role" => "coordinator",
            "response_mode" => "coordinator"
          })
      end
    end)
    |> Repo.transaction()
    |> case do
      {:ok, %{room: room}} -> {:ok, get_room!(room.id)}
      {:error, _operation, changeset, _changes} -> {:error, changeset}
    end
  end

  def update_room(%Room{} = room, attrs) do
    room
    |> Room.changeset(stringify_keys(attrs))
    |> Repo.update()
    |> case do
      {:ok, room} -> {:ok, get_room!(room.id)}
      error -> error
    end
  end

  def create_member(%Room{} = room, attrs) do
    attrs = stringify_keys(attrs)

    attrs =
      attrs
      |> Map.put("workspace_id", room.workspace_id)
      |> Map.put("room_id", room.id)
      |> Map.put_new_lazy("mention_handle", fn ->
        coordinator_handle(room.workspace_id, attrs["agent_id"])
      end)

    with :ok <- validate_agent_workspace(room.workspace_id, attrs["agent_id"]) do
      %Member{} |> Member.changeset(attrs) |> Repo.insert()
    end
  end

  def delete_member(%Room{} = room, agent_id) do
    Member
    |> where([member], member.room_id == ^room.id and member.agent_id == ^normalize_id(agent_id))
    |> Repo.one()
    |> case do
      nil -> {:error, :not_found}
      member -> Repo.delete(member)
    end
  end

  def list_messages(%Room{} = room, opts \\ []) do
    limit = opt(opts, :limit, 100)

    Message
    |> where([message], message.room_id == ^room.id)
    |> maybe_filter_message_query(opt(opts, :query) || opt(opts, :q))
    |> maybe_filter(:author_type, opt(opts, :author_type))
    |> maybe_filter(:agent_id, normalize_id(opt(opts, :agent_id)))
    |> maybe_filter(:source_channel, opt(opts, :source_channel) || opt(opts, :channel))
    |> maybe_filter_inserted_after(opt(opts, :from) || opt(opts, :inserted_after))
    |> maybe_filter_inserted_before(opt(opts, :to) || opt(opts, :inserted_before))
    |> maybe_filter_delivery_status(opt(opts, :delivery_status))
    |> order_by([message], asc: message.inserted_at, asc: message.id)
    |> limit(^limit)
    |> preload([:agent, deliveries: :channel_binding])
    |> Repo.all()
  end

  def create_system_message(%Room{} = room, content, metadata \\ %{}) do
    Message.changeset(%Message{}, %{
      "workspace_id" => room.workspace_id,
      "room_id" => room.id,
      "author_type" => "system",
      "source_channel" => "system",
      "content" => content,
      "metadata" => stringify_keys(metadata || %{})
    })
    |> Repo.insert()
  end

  def export_transcript(%Room{} = room, opts \\ []) do
    messages = list_messages(room, opts)

    %{
      room: %{
        id: room.id,
        title: room.title,
        slug: room.slug,
        workspace_id: room.workspace_id
      },
      messages:
        Enum.map(messages, fn message ->
          %{
            id: message.id,
            author_type: message.author_type,
            agent_id: message.agent_id,
            agent_name: message.agent && message.agent.name,
            source_channel: message.source_channel,
            external_message_id: message.external_message_id,
            content: message.content,
            metadata: message.metadata,
            inserted_at: message.inserted_at
          }
        end)
    }
  end

  def send_user_message(%Room{} = room, content, opts \\ []) when is_binary(content) do
    room = get_room!(room.id)
    content = String.trim(content)

    cond do
      room.status != "active" ->
        {:error, %{"reason" => "room_not_active"}}

      content == "" ->
        {:error, %{"reason" => "empty_room_message"}}

      true ->
        do_send_user_message(room, expand_plugin_command(room.workspace_id, content), opts)
    end
  end

  def approve_proposal(%Room{} = room, proposal_id, opts \\ []) do
    room = get_room!(room.id)
    approved_by = Keyword.get(opts, :approved_by, "operator")
    selected_agent_ids = Keyword.get(opts, :agent_ids)

    with {:ok, proposal} <- get_room_message(room, proposal_id),
         :ok <- validate_pending_proposal(proposal),
         {:ok, source_message} <- get_room_message(room, proposal.metadata["source_message_id"]),
         pending_agent_ids <- normalize_ids(proposal.metadata["pending_agent_ids"] || []),
         approved_agent_ids <- approve_agent_ids(pending_agent_ids, selected_agent_ids),
         :ok <- validate_non_empty_approval(approved_agent_ids),
         members <- members_for_agent_ids(room.members || [], approved_agent_ids),
         :ok <- validate_all_members_found(approved_agent_ids, members),
         {:ok, agent_messages} <- respond_with_members(room, source_message, members),
         {:ok, proposal} <-
           mark_proposal_approved(proposal, agent_messages, approved_agent_ids, approved_by) do
      deliver_source_channel_replies(room, source_message, agent_messages)
      {:ok, %{proposal: proposal, agent_messages: agent_messages}}
    end
  end

  def create_channel_binding(%Room{} = room, attrs) do
    attrs =
      attrs
      |> stringify_keys()
      |> Map.put("workspace_id", room.workspace_id)
      |> Map.put("room_id", room.id)
      |> maybe_allow_plugin_room_channel(room.workspace_id)

    %ChannelBinding{} |> ChannelBinding.changeset(attrs) |> Repo.insert()
  end

  def room_channel_specs(workspace_id) do
    [
      %{
        "provider" => "telegram",
        "label" => "Telegram",
        "delivery" => "built_in",
        "config_fields" => ["token_env", "secret_env", "external_chat_id"]
      }
    ] ++ Plugins.enabled_room_channel_specs(workspace_id)
  end

  def plugin_command_specs(workspace_id) do
    Plugins.enabled_cli_command_specs(workspace_id)
  end

  def list_channel_bindings(%Room{} = room) do
    ChannelBinding
    |> where([binding], binding.room_id == ^room.id)
    |> order_by([binding], asc: binding.provider, asc: binding.slug)
    |> Repo.all()
  end

  def telegram_setup_readiness(%ChannelBinding{provider: "telegram"} = binding) do
    items = telegram_setup_items(binding)
    failed_deliveries = delivery_count(binding, "failed")
    pending_deliveries = delivery_count(binding, "pending")
    sent_deliveries = delivery_count(binding, "sent") + delivery_count(binding, "delivered")

    %{
      "status" => setup_status(items),
      "webhook_path" => telegram_webhook_path(binding),
      "webhook_url" => telegram_webhook_url(binding),
      "set_webhook_command" => telegram_setup_command(binding),
      "capture_pending" => capture_telegram_chat?(binding),
      "delivery_counts" => %{
        "failed" => failed_deliveries,
        "pending" => pending_deliveries,
        "sent" => sent_deliveries
      },
      "items" => items
    }
  end

  def list_deliveries(%Room{} = room, opts \\ []) do
    limit = opt(opts, :limit, 100)

    Delivery
    |> where([delivery], delivery.room_id == ^room.id)
    |> maybe_filter(:status, opt(opts, :status))
    |> maybe_filter(:provider, opt(opts, :provider))
    |> order_by([delivery], desc: delivery.inserted_at, desc: delivery.id)
    |> limit(^limit)
    |> preload([:message, :channel_binding])
    |> Repo.all()
  end

  def get_active_binding_by_slug(provider, slug) do
    ChannelBinding
    |> where(
      [binding],
      binding.provider == ^provider and binding.slug == ^slug and binding.status == "active"
    )
    |> preload([:room])
    |> Repo.one()
  end

  def get_channel_binding_for_room!(%Room{} = room, id) do
    ChannelBinding
    |> where([binding], binding.room_id == ^room.id and binding.id == ^normalize_id(id))
    |> Repo.one!()
  end

  def get_delivery_for_room!(%Room{} = room, id) do
    Delivery
    |> where([delivery], delivery.room_id == ^room.id and delivery.id == ^normalize_id(id))
    |> preload([:message, :channel_binding])
    |> Repo.one!()
  end

  def retry_delivery(%Delivery{provider: "telegram"} = delivery) do
    delivery = Repo.preload(delivery, [:message, :channel_binding])
    deliver_telegram_messages(delivery.channel_binding, [delivery.message])
  end

  def receive_telegram_update(
        %ChannelBinding{provider: "telegram"} = binding,
        update,
        headers \\ []
      ) do
    update = stringify_keys(update || %{})

    with :ok <- verify_telegram_secret(binding, headers),
         {:ok, chat_id} <- telegram_chat_id(update),
         {:ok, binding} <- verify_telegram_chat(binding, chat_id),
         {:ok, message_id} <- telegram_message_id(update),
         {:ok, content} <- telegram_text(update),
         room <- binding.room || get_room!(binding.room_id),
         {:ok, result} <- receive_or_reuse_telegram_message(room, message_id, content, update) do
      mark_binding_received(binding)
      deliver_telegram_messages(binding, result.agent_messages)
      {:ok, result}
    else
      {:error, error} ->
        mark_binding_error(binding, normalize_error(error))
        {:error, normalize_error(error)}
    end
  end

  def retry_channel_binding(%ChannelBinding{provider: "telegram"} = binding) do
    deliver_telegram_messages(binding, pending_telegram_messages(binding))
  end

  def deliver_telegram_messages(%ChannelBinding{} = binding, messages) do
    messages =
      messages
      |> Enum.filter(&pending_telegram_delivery?(binding, &1))
      |> Enum.sort_by(& &1.id)

    Enum.reduce_while(messages, {:ok, [], binding}, fn message, {:ok, sent, binding} ->
      {:ok, delivery} = ensure_delivery(binding, message)

      case post_telegram_message(binding, message.content) do
        {:ok, response} ->
          {:ok, _delivery} = mark_delivery_sent(delivery, response)
          {:ok, binding} = mark_binding_sent(binding, message.id)
          {:cont, {:ok, sent ++ [response], binding}}

        {:error, error} ->
          mark_delivery_failed(delivery, error)
          mark_binding_delivery_error(binding, error)
          {:halt, {:error, error}}
      end
    end)
    |> case do
      {:ok, sent, _binding} -> {:ok, sent}
      {:error, error} -> {:error, error}
    end
  end

  def send_telegram_message(%ChannelBinding{} = binding, content) do
    post_telegram_message(binding, content)
  end

  defp post_telegram_message(%ChannelBinding{} = binding, content) do
    with :ok <- validate_telegram_delivery_target(binding),
         {:ok, token} <- Secrets.fetch_env(binding.token_env),
         {:ok, response} <-
           Req.post("https://api.telegram.org/bot#{token}/sendMessage",
             json: %{"chat_id" => binding.external_chat_id, "text" => content}
           ),
         true <- response.status in 200..299 do
      {:ok, response.body}
    else
      false -> {:error, %{"reason" => "telegram_delivery_failed"}}
      {:error, error} -> {:error, normalize_error(error)}
    end
  end

  defp maybe_allow_plugin_room_channel(attrs, workspace_id) do
    provider = attrs["provider"]

    plugin_providers =
      workspace_id
      |> Plugins.enabled_room_channel_specs()
      |> Enum.map(&(&1["provider"] || &1["name"]))

    if provider in plugin_providers do
      metadata =
        attrs
        |> Map.get("metadata", %{})
        |> Map.merge(%{"plugin_allowed_providers" => [provider]})

      Map.put(attrs, "metadata", metadata)
    else
      attrs
    end
  end

  defp expand_plugin_command(workspace_id, "/" <> command_text = content) do
    [command | rest] = String.split(command_text, " ", parts: 2)
    args = List.first(rest) || ""
    command = "/" <> command

    workspace_id
    |> plugin_command_specs()
    |> Enum.find(&plugin_command_matches?(&1, command))
    |> case do
      nil ->
        content

      spec ->
        prompt = spec["prompt"] || spec["description"] || content

        [prompt, args]
        |> Enum.reject(&(&1 == ""))
        |> Enum.join("\n\n")
    end
  end

  defp expand_plugin_command(_workspace_id, content), do: content

  defp plugin_command_matches?(spec, command) do
    commands =
      [spec["command"], spec["name"]]
      |> Enum.concat(List.wrap(spec["aliases"] || []))
      |> Enum.reject(&is_nil/1)
      |> Enum.map(fn value ->
        value = to_string(value)
        if String.starts_with?(value, "/"), do: value, else: "/#{value}"
      end)

    command in commands
  end

  defp telegram_setup_items(binding) do
    [
      setup_item("Public host", public_host_status(), public_host_message()),
      setup_item("Webhook URL", "ok", telegram_webhook_url(binding)),
      env_setup_item("Bot token", binding.token_env, required?: true),
      env_setup_item("Secret token", binding.secret_env, required?: false),
      chat_setup_item(binding),
      timestamp_setup_item(
        "Inbound proof",
        binding.last_received_at,
        "No inbound Telegram message received yet"
      ),
      timestamp_setup_item(
        "Outbound proof",
        binding.last_sent_at,
        "No outbound Telegram delivery confirmed yet"
      ),
      delivery_setup_item(binding),
      last_error_setup_item(binding)
    ]
  end

  defp setup_item(label, status, text),
    do: %{"label" => label, "status" => status, "text" => text}

  defp public_host_status do
    if present(System.get_env("PHX_HOST")), do: "ok", else: "warning"
  end

  defp public_host_message do
    case present(System.get_env("PHX_HOST")) do
      nil -> "PHX_HOST is not set; webhook command uses a placeholder"
      host -> "https://#{host}"
    end
  end

  defp env_setup_item(label, env, opts) do
    required? = Keyword.fetch!(opts, :required?)

    cond do
      present(env) == nil and required? ->
        setup_item(label, "error", "Environment variable name is missing")

      present(env) == nil ->
        setup_item(label, "warning", "Secret header is recommended for production")

      match?({:ok, _secret}, Secrets.fetch_env(env)) ->
        setup_item(label, "ok", "#{Secrets.safe_ref(env)} is configured")

      true ->
        status = if required?, do: "error", else: "error"
        setup_item(label, status, "#{Secrets.safe_ref(env)} is not set")
    end
  end

  defp chat_setup_item(binding) do
    if capture_telegram_chat?(binding) do
      setup_item("Chat binding", "warning", "Waiting for first inbound Telegram message")
    else
      setup_item("Chat binding", "ok", "Chat id captured")
    end
  end

  defp timestamp_setup_item(label, nil, missing), do: setup_item(label, "warning", missing)

  defp timestamp_setup_item(label, timestamp, _missing),
    do: setup_item(label, "ok", "Last seen #{timestamp}")

  defp delivery_setup_item(binding) do
    failed = delivery_count(binding, "failed")
    pending = delivery_count(binding, "pending")
    sent = delivery_count(binding, "sent") + delivery_count(binding, "delivered")

    cond do
      failed > 0 ->
        setup_item("Delivery receipts", "error", "#{failed} failed delivery receipts need retry")

      pending > 0 ->
        setup_item("Delivery receipts", "warning", "#{pending} pending delivery receipts")

      sent > 0 ->
        setup_item("Delivery receipts", "ok", "#{sent} sent delivery receipts")

      true ->
        setup_item("Delivery receipts", "warning", "No delivery receipts recorded yet")
    end
  end

  defp last_error_setup_item(%{last_error: error}) when is_map(error) and map_size(error) > 0 do
    setup_item("Last error", "error", error["reason"] || inspect(error))
  end

  defp last_error_setup_item(_binding),
    do: setup_item("Last error", "ok", "No recorded Telegram error")

  defp setup_status(items) do
    statuses = Enum.map(items, & &1["status"])

    cond do
      "error" in statuses -> "needs_attention"
      "warning" in statuses -> "setup_pending"
      true -> "ready"
    end
  end

  defp telegram_webhook_path(binding), do: "/api/v1/telegram/#{binding.slug}/webhook"

  defp telegram_webhook_url(binding) do
    host = present(System.get_env("PHX_HOST")) || "$PHX_HOST"
    "https://#{host}#{telegram_webhook_path(binding)}"
  end

  defp telegram_setup_command(binding) do
    secret_part =
      if present(binding.secret_env) do
        ~s(,"secret_token":"$#{binding.secret_env}")
      else
        ""
      end

    ~s(curl -X POST "https://api.telegram.org/bot$#{binding.token_env || "TELEGRAM_BOT_TOKEN"}/setWebhook" -H "content-type: application/json" -d '{"url":"#{telegram_webhook_url(binding)}"#{secret_part}}')
  end

  defp delivery_count(binding, status) do
    Delivery
    |> where(
      [delivery],
      delivery.channel_binding_id == ^binding.id and delivery.status == ^status
    )
    |> Repo.aggregate(:count)
  end

  defp validate_telegram_delivery_target(%ChannelBinding{} = binding) do
    if capture_telegram_chat?(binding) do
      {:error, %{"reason" => "telegram_chat_id_capture_pending"}}
    else
      :ok
    end
  end

  defp do_send_user_message(room, content, opts) do
    source_channel = Keyword.get(opts, :source_channel, "web")
    external_message_id = Keyword.get(opts, :external_message_id)
    metadata = Keyword.get(opts, :metadata, %{})

    Multi.new()
    |> Multi.insert(
      :user_message,
      Message.changeset(%Message{}, %{
        "workspace_id" => room.workspace_id,
        "room_id" => room.id,
        "author_type" => "user",
        "source_channel" => source_channel,
        "external_message_id" => external_message_id,
        "content" => content,
        "metadata" => metadata
      })
    )
    |> Multi.update(:room, Room.changeset(room, %{"last_message_at" => now()}))
    |> Repo.transaction()
    |> case do
      {:ok, %{user_message: user_message}} ->
        respond_to_room_message(room, user_message)

      {:error, _operation, changeset, _changes} ->
        {:error, changeset}
    end
  end

  defp respond_to_room_message(room, user_message) do
    members = room.members || []
    targets = route_targets(room, user_message.content, members)

    cond do
      targets == [] ->
        {:ok, %{user_message: user_message, agent_messages: [], pending_proposal: nil}}

      length(targets) > 1 ->
        {:ok, proposal} =
          create_system_message(
            room,
            "Multiple agents are ready to respond. Approve in Hydra Studio.",
            %{
              "pending_agent_ids" => Enum.map(targets, & &1.agent_id),
              "source_message_id" => user_message.id,
              "proposal_status" => "pending_multi_agent_response"
            }
          )

        {:ok, %{user_message: user_message, agent_messages: [], pending_proposal: proposal}}

      true ->
        [member] = targets
        {:ok, agent_message} = respond_with_member(room, user_message, member)

        {:ok,
         %{user_message: user_message, agent_messages: [agent_message], pending_proposal: nil}}
    end
  end

  defp respond_with_member(room, user_message, %Member{} = member) do
    agent = member.agent || Runtime.get_agent_for_workspace!(room.workspace_id, member.agent_id)
    {:ok, conversation} = get_or_create_room_conversation(room, agent)
    {:ok, response} = AgentChat.respond(conversation, user_message.content, source: "room")

    create_agent_message(room, agent, response, %{
      "source_user_message_id" => user_message.id,
      "source_channel" => user_message.source_channel,
      "routing" => "room"
    })
  end

  defp respond_with_members(room, source_message, members) do
    Enum.reduce_while(members, {:ok, []}, fn member, {:ok, messages} ->
      case respond_with_member(room, source_message, member) do
        {:ok, message} -> {:cont, {:ok, messages ++ [message]}}
        {:error, error} -> {:halt, {:error, normalize_error(error)}}
      end
    end)
  end

  defp create_agent_message(room, agent, response, metadata) do
    {source_channel, metadata} = Map.pop(metadata, "source_channel", "web")

    Message.changeset(%Message{}, %{
      "workspace_id" => room.workspace_id,
      "room_id" => room.id,
      "agent_id" => agent.id,
      "conversation_id" => response.conversation.id,
      "turn_id" => response.assistant_turn.id,
      "author_type" => "agent",
      "source_channel" => source_channel,
      "content" => response.assistant_turn.content,
      "metadata" =>
        Map.merge(metadata, %{
          "provider" => response.provider_response["provider"],
          "model" => response.provider_response["model"]
        })
    })
    |> Repo.insert()
  end

  defp get_room_message(_room, nil), do: {:error, %{"reason" => "room_message_missing"}}

  defp get_room_message(room, message_id) do
    Message
    |> where([message], message.room_id == ^room.id and message.id == ^normalize_id(message_id))
    |> preload([:agent])
    |> Repo.one()
    |> case do
      nil -> {:error, %{"reason" => "room_message_not_found"}}
      message -> {:ok, message}
    end
  end

  defp validate_pending_proposal(%Message{author_type: "system", metadata: metadata}) do
    if metadata["proposal_status"] == "pending_multi_agent_response" do
      :ok
    else
      {:error, %{"reason" => "room_proposal_not_pending"}}
    end
  end

  defp validate_pending_proposal(_message),
    do: {:error, %{"reason" => "room_proposal_not_pending"}}

  defp approve_agent_ids(pending_agent_ids, nil), do: pending_agent_ids
  defp approve_agent_ids(pending_agent_ids, []), do: pending_agent_ids

  defp approve_agent_ids(pending_agent_ids, selected_agent_ids) do
    selected_agent_ids
    |> normalize_ids()
    |> Enum.filter(&(&1 in pending_agent_ids))
  end

  defp validate_non_empty_approval([]),
    do: {:error, %{"reason" => "room_proposal_no_agents_selected"}}

  defp validate_non_empty_approval(_agent_ids), do: :ok

  defp members_for_agent_ids(members, agent_ids) do
    agent_ids
    |> Enum.map(fn agent_id -> Enum.find(members, &(&1.agent_id == agent_id)) end)
    |> Enum.reject(&is_nil/1)
  end

  defp validate_all_members_found(agent_ids, members) do
    member_agent_ids = Enum.map(members, & &1.agent_id)

    missing_agent_ids = Enum.reject(agent_ids, &(&1 in member_agent_ids))

    if missing_agent_ids == [] do
      :ok
    else
      {:error, %{"reason" => "room_proposal_member_missing", "agent_ids" => missing_agent_ids}}
    end
  end

  defp mark_proposal_approved(proposal, agent_messages, approved_agent_ids, approved_by) do
    metadata =
      Map.merge(proposal.metadata || %{}, %{
        "proposal_status" => "approved_multi_agent_response",
        "approved_agent_ids" => approved_agent_ids,
        "approved_message_ids" => Enum.map(agent_messages, & &1.id),
        "approved_by" => approved_by,
        "approved_at" => DateTime.to_iso8601(now())
      })

    proposal
    |> Message.changeset(%{"metadata" => metadata})
    |> Repo.update()
  end

  defp deliver_source_channel_replies(room, %Message{source_channel: "telegram"}, messages) do
    ChannelBinding
    |> where(
      [binding],
      binding.room_id == ^room.id and binding.provider == "telegram" and
        binding.status == "active"
    )
    |> Repo.all()
    |> Enum.each(&deliver_telegram_messages(&1, messages))
  end

  defp deliver_source_channel_replies(_room, _source_message, _messages), do: :ok

  defp get_or_create_room_conversation(room, agent) do
    HydraAgent.Runtime.Conversation
    |> where([conversation], conversation.workspace_id == ^room.workspace_id)
    |> where([conversation], conversation.agent_id == ^agent.id)
    |> where([conversation], conversation.channel == "room")
    |> where(
      [conversation],
      fragment("?->>? = ?", conversation.metadata, "room_id", ^to_string(room.id))
    )
    |> Repo.one()
    |> case do
      nil ->
        AgentChat.start_conversation(agent, %{
          title: "Room: #{room.title}",
          channel: "room",
          metadata: %{"room_id" => room.id}
        })

      conversation ->
        {:ok, conversation}
    end
  end

  defp route_targets(room, content, members) do
    mentions = mentioned_handles(content)

    mentioned =
      members
      |> Enum.filter(&(&1.mention_handle in mentions))
      |> Enum.reject(&(&1.role == "observer" or &1.response_mode == "silent"))
      |> Enum.sort_by(fn member ->
        Enum.find_index(mentions, &(&1 == member.mention_handle)) || 0
      end)

    cond do
      mentioned != [] ->
        mentioned

      room.coordinator_agent_id ->
        Enum.filter(members, &(&1.agent_id == room.coordinator_agent_id))

      true ->
        members
        |> Enum.reject(&(&1.role == "observer" or &1.response_mode == "silent"))
        |> Enum.sort_by(&{&1.priority, &1.id})
        |> Enum.take(1)
    end
  end

  defp mentioned_handles(content) do
    ~r/@([a-zA-Z0-9][a-zA-Z0-9-]*)/
    |> Regex.scan(content)
    |> Enum.map(fn [_match, handle] -> String.downcase(handle) end)
  end

  defp coordinator_handle(workspace_id, agent_id) do
    Runtime.get_agent_for_workspace!(workspace_id, agent_id).slug
  end

  defp validate_agent_workspace(workspace_id, agent_id) do
    Runtime.get_agent_for_workspace!(workspace_id, agent_id)
    :ok
  end

  defp receive_or_reuse_telegram_message(room, message_id, content, update) do
    case external_message(room, "telegram", message_id) do
      nil ->
        send_user_message(room, content,
          source_channel: "telegram",
          external_message_id: message_id,
          metadata: %{"telegram_update_id" => update["update_id"]}
        )

      message ->
        {:ok,
         %{
           user_message: message,
           agent_messages: [],
           pending_proposal: nil,
           duplicate?: true
         }}
    end
  end

  defp external_message(room, source_channel, external_message_id) do
    Message
    |> where(
      [message],
      message.room_id == ^room.id and message.source_channel == ^source_channel and
        message.external_message_id == ^external_message_id
    )
    |> Repo.one()
  end

  defp pending_telegram_messages(binding) do
    Message
    |> where(
      [message],
      message.room_id == ^binding.room_id and message.author_type == "agent" and
        message.source_channel == "telegram"
    )
    |> order_by([message], asc: message.id)
    |> Repo.all()
    |> Enum.filter(&pending_telegram_delivery?(binding, &1))
  end

  defp pending_telegram_delivery?(binding, %Message{
         id: id,
         author_type: "agent",
         source_channel: "telegram"
       }) do
    case delivery_for_message(binding, id) do
      %Delivery{status: status} when status in ["sent", "delivered", "skipped"] -> false
      %Delivery{} -> true
      nil -> id > delivery_cursor(binding)
    end
  end

  defp pending_telegram_delivery?(_binding, _message), do: false

  defp delivery_cursor(%ChannelBinding{metadata: metadata}) do
    case metadata && metadata["delivery_cursor_message_id"] do
      id when is_integer(id) -> id
      id when is_binary(id) -> normalize_id(id) || 0
      _other -> 0
    end
  end

  defp mark_binding_sent(binding, message_id) do
    metadata =
      (binding.metadata || %{})
      |> Map.put("delivery_cursor_message_id", message_id)

    binding
    |> ChannelBinding.changeset(%{
      "last_sent_at" => now(),
      "last_error" => %{},
      "metadata" => metadata
    })
    |> Repo.update()
  end

  defp mark_binding_delivery_error(binding, error) do
    binding
    |> ChannelBinding.changeset(%{
      "last_error" => %{
        "reason" => "telegram_delivery_failed",
        "detail" => normalize_error(error)
      }
    })
    |> Repo.update()
  end

  defp ensure_delivery(%ChannelBinding{} = binding, %Message{} = message) do
    case delivery_for_message(binding, message.id) do
      %Delivery{} = delivery ->
        {:ok, delivery}

      nil ->
        %Delivery{}
        |> Delivery.changeset(%{
          "workspace_id" => binding.workspace_id,
          "room_id" => binding.room_id,
          "message_id" => message.id,
          "channel_binding_id" => binding.id,
          "provider" => binding.provider,
          "status" => "pending",
          "attempts" => 0
        })
        |> Repo.insert()
    end
  end

  defp delivery_for_message(%ChannelBinding{} = binding, message_id) do
    Delivery
    |> where(
      [delivery],
      delivery.channel_binding_id == ^binding.id and delivery.message_id == ^message_id
    )
    |> Repo.one()
  end

  defp mark_delivery_sent(%Delivery{} = delivery, response) do
    external_message_id =
      case response do
        %{"result" => %{"message_id" => message_id}} -> to_string(message_id)
        %{"message_id" => message_id} -> to_string(message_id)
        _other -> delivery.external_message_id
      end

    delivery
    |> Delivery.changeset(%{
      "status" => "sent",
      "attempts" => delivery.attempts + 1,
      "external_message_id" => external_message_id,
      "sent_at" => now(),
      "last_error" => %{},
      "metadata" => Map.put(delivery.metadata || %{}, "last_response", response || %{})
    })
    |> Repo.update()
  end

  defp mark_delivery_failed(%Delivery{} = delivery, error) do
    delivery
    |> Delivery.changeset(%{
      "status" => "failed",
      "attempts" => delivery.attempts + 1,
      "last_error" => normalize_error(error)
    })
    |> Repo.update()
  end

  defp telegram_chat_id(%{"message" => %{"chat" => %{"id" => id}}}), do: {:ok, to_string(id)}
  defp telegram_chat_id(_update), do: {:error, %{"reason" => "telegram_chat_id_missing"}}

  defp telegram_message_id(%{"message" => %{"message_id" => id}}), do: {:ok, to_string(id)}
  defp telegram_message_id(_update), do: {:error, %{"reason" => "telegram_message_id_missing"}}

  defp telegram_text(%{"message" => %{"text" => text}}) when is_binary(text) and text != "",
    do: {:ok, text}

  defp telegram_text(_update), do: {:error, %{"reason" => "telegram_text_missing"}}

  defp verify_telegram_chat(binding, chat_id) do
    cond do
      binding.external_chat_id == chat_id ->
        {:ok, binding}

      capture_telegram_chat?(binding) ->
        binding
        |> ChannelBinding.changeset(%{
          "external_chat_id" => chat_id,
          "config" => Map.put(binding.config || %{}, "capture_chat_id", false)
        })
        |> Repo.update()

      true ->
        {:error, %{"reason" => "telegram_chat_mismatch"}}
    end
  end

  defp capture_telegram_chat?(%ChannelBinding{external_chat_id: external_chat_id, config: config}) do
    String.starts_with?(to_string(external_chat_id || ""), "pending:") and
      get_in(config || %{}, ["capture_chat_id"]) == true
  end

  defp verify_telegram_secret(%ChannelBinding{secret_env: secret_env}, _headers)
       when secret_env in [nil, ""],
       do: :ok

  defp verify_telegram_secret(%ChannelBinding{secret_env: secret_env}, headers) do
    headers = Map.new(headers, fn {key, value} -> {String.downcase(to_string(key)), value} end)

    with {:ok, expected} <- Secrets.fetch_env(secret_env),
         received when is_binary(received) <- headers["x-telegram-bot-api-secret-token"],
         true <- Plug.Crypto.secure_compare(received, expected) do
      :ok
    else
      false -> {:error, %{"reason" => "invalid_telegram_secret"}}
      nil -> {:error, %{"reason" => "missing_telegram_secret"}}
      {:error, error} -> {:error, error}
      _other -> {:error, %{"reason" => "invalid_telegram_secret"}}
    end
  end

  defp mark_binding_received(binding) do
    binding
    |> ChannelBinding.changeset(%{"last_received_at" => now(), "last_error" => %{}})
    |> Repo.update()
  end

  defp mark_binding_error(binding, error) do
    binding
    |> ChannelBinding.changeset(%{"last_received_at" => now(), "last_error" => error})
    |> Repo.update()
  end

  defp preload_room(room) do
    Repo.preload(room, [
      :coordinator_agent,
      members: [:agent],
      messages: [:agent],
      channel_bindings: []
    ])
  end

  defp normalize_error(%Ecto.Changeset{} = changeset),
    do: %{"reason" => "changeset_error", "errors" => changeset_errors(changeset)}

  defp normalize_error(error) when is_map(error), do: error
  defp normalize_error(error), do: %{"reason" => inspect(error)}

  defp present(value) when is_binary(value) do
    value = String.trim(value)
    if value == "", do: nil, else: value
  end

  defp present(_value), do: nil

  defp changeset_errors(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
      Enum.reduce(opts, message, fn {key, value}, acc ->
        String.replace(acc, "%{#{key}}", to_string(value))
      end)
    end)
  end

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:microsecond)

  defp opt(opts, key) when is_list(opts), do: Keyword.get(opts, key)
  defp opt(opts, key) when is_map(opts), do: Map.get(opts, to_string(key))
  defp opt(opts, key, default) when is_list(opts), do: Keyword.get(opts, key, default)
  defp opt(opts, key, default) when is_map(opts), do: Map.get(opts, to_string(key), default)

  defp maybe_filter(query, _field, nil), do: query
  defp maybe_filter(query, _field, ""), do: query

  defp maybe_filter(query, field, value) do
    where(query, [record], field(record, ^field) == ^value)
  end

  defp maybe_filter_message_query(query, nil), do: query
  defp maybe_filter_message_query(query, ""), do: query

  defp maybe_filter_message_query(query, value) when is_binary(value) do
    pattern = "%#{String.trim(value)}%"
    where(query, [message], ilike(message.content, ^pattern))
  end

  defp maybe_filter_inserted_after(query, value) do
    case parse_datetime(value) do
      {:ok, datetime} -> where(query, [message], message.inserted_at >= ^datetime)
      :error -> query
    end
  end

  defp maybe_filter_inserted_before(query, value) do
    case parse_datetime(value) do
      {:ok, datetime} -> where(query, [message], message.inserted_at <= ^datetime)
      :error -> query
    end
  end

  defp maybe_filter_delivery_status(query, nil), do: query
  defp maybe_filter_delivery_status(query, ""), do: query

  defp maybe_filter_delivery_status(query, status) do
    query
    |> join(:inner, [message], delivery in assoc(message, :deliveries))
    |> where([_message, delivery], delivery.status == ^status)
    |> distinct([message], message.id)
  end

  defp parse_datetime(nil), do: :error
  defp parse_datetime(""), do: :error
  defp parse_datetime(%DateTime{} = datetime), do: {:ok, datetime}

  defp parse_datetime(%NaiveDateTime{} = datetime),
    do: {:ok, DateTime.from_naive!(datetime, "Etc/UTC")}

  defp parse_datetime(value) when is_binary(value) do
    cond do
      match?({:ok, _datetime, _offset}, DateTime.from_iso8601(value)) ->
        {:ok, datetime, _offset} = DateTime.from_iso8601(value)
        {:ok, datetime}

      match?({:ok, _date}, Date.from_iso8601(value)) ->
        {:ok, date} = Date.from_iso8601(value)
        {:ok, DateTime.new!(date, ~T[00:00:00], "Etc/UTC")}

      true ->
        :error
    end
  end

  defp parse_datetime(_value), do: :error

  defp normalize_id(id) when is_binary(id) do
    case Integer.parse(id) do
      {parsed, ""} -> parsed
      _other -> nil
    end
  end

  defp normalize_id(id), do: id

  defp normalize_ids(ids) when is_list(ids), do: Enum.map(ids, &normalize_id/1)
  defp normalize_ids(id), do: [normalize_id(id)]

  defp stringify_keys(map) when is_map(map),
    do: Map.new(map, fn {key, value} -> {to_string(key), value} end)
end
