defmodule HydraAgent.RoomsTest do
  use HydraAgent.DataCase

  import HydraAgent.RuntimeFixtures

  alias HydraAgent.{Rooms, Runtime}

  setup do
    workspace = workspace_fixture()

    {:ok, _provider} =
      Runtime.create_provider(%{
        workspace_id: workspace.id,
        name: "mock",
        kind: "mock",
        model: "mock-model"
      })

    coordinator =
      agent_fixture(workspace, %{
        name: "Coordinator",
        slug: "coordinator",
        model_route: %{"default_provider" => "mock"}
      })

    builder =
      agent_fixture(workspace, %{
        name: "Builder",
        slug: "builder",
        model_route: %{"default_provider" => "mock"}
      })

    {:ok, room} =
      Rooms.create_room(%{
        workspace_id: workspace.id,
        coordinator_agent_id: coordinator.id,
        title: "Delivery Room",
        slug: "delivery-room"
      })

    {:ok, _member} = Rooms.create_member(room, %{agent_id: builder.id, mention_handle: "builder"})

    {:ok,
     workspace: workspace,
     coordinator: coordinator,
     builder: builder,
     room: Rooms.get_room!(room.id)}
  end

  test "routes unmentioned room messages to the coordinator", %{
    room: room,
    coordinator: coordinator
  } do
    assert {:ok, result} = Rooms.send_user_message(room, "hello room")

    assert result.user_message.author_type == "user"
    assert [agent_message] = result.agent_messages
    assert agent_message.agent_id == coordinator.id
    assert agent_message.content == "mock: hello room"

    room = Rooms.get_room!(room.id)
    messages = Rooms.list_messages(room)
    assert Enum.map(messages, & &1.author_type) == ["user", "agent"]
  end

  test "filters room messages and transcript exports", %{room: room} do
    {:ok, _first} = Rooms.send_user_message(room, "alpha briefing")
    {:ok, _second} = Rooms.send_user_message(room, "beta research")

    messages = Rooms.list_messages(room, query: "beta", author_type: "user")
    assert Enum.map(messages, & &1.content) == ["beta research"]

    transcript = Rooms.export_transcript(room, query: "alpha", author_type: "user")
    assert [%{content: "alpha briefing"}] = transcript.messages
  end

  test "routes mentions to the named agent", %{room: room, builder: builder} do
    assert {:ok, result} = Rooms.send_user_message(room, "@builder please review this")

    assert [agent_message] = result.agent_messages
    assert agent_message.agent_id == builder.id
    assert agent_message.content == "mock: @builder please review this"
  end

  test "multiple mentions create a pending proposal instead of fan-out", %{
    room: room,
    coordinator: coordinator
  } do
    assert {:ok, result} = Rooms.send_user_message(room, "@coordinator @builder compare plans")

    assert result.agent_messages == []
    assert result.pending_proposal.author_type == "system"
    assert coordinator.id in result.pending_proposal.metadata["pending_agent_ids"]
  end

  test "approves pending multi-agent room proposals", %{
    room: room,
    coordinator: coordinator,
    builder: builder
  } do
    {:ok, result} = Rooms.send_user_message(room, "@coordinator @builder compare plans")

    assert {:ok, approval} = Rooms.approve_proposal(room, result.pending_proposal.id)

    assert Enum.map(approval.agent_messages, & &1.agent_id) == [coordinator.id, builder.id]

    assert Enum.map(approval.agent_messages, & &1.content) == [
             "mock: @coordinator @builder compare plans",
             "mock: @coordinator @builder compare plans"
           ]

    messages = Rooms.get_room!(room.id) |> Rooms.list_messages()
    proposal = Enum.find(messages, &(&1.id == result.pending_proposal.id))
    assert proposal.metadata["proposal_status"] == "approved_multi_agent_response"
    assert proposal.metadata["approved_agent_ids"] == [coordinator.id, builder.id]
  end

  test "telegram delivery failures are visible and retryable", %{room: room} do
    {:ok, binding} =
      Rooms.create_channel_binding(room, %{
        provider: "telegram",
        slug: "delivery-telegram-retry",
        external_chat_id: "-1002"
      })

    assert {:ok, result} =
             Rooms.send_user_message(room, "hello from telegram", source_channel: "telegram")

    assert [_agent_message] = result.agent_messages

    assert {:error, %{"reason" => "missing_secret_env"}} =
             Rooms.retry_channel_binding(binding)

    [binding] = Rooms.list_channel_bindings(room)
    assert binding.last_error["reason"] == "telegram_delivery_failed"
    assert binding.last_error["detail"]["reason"] == "missing_secret_env"

    [delivery] = Rooms.list_deliveries(room, status: "failed")
    assert delivery.message_id == hd(result.agent_messages).id
    assert delivery.attempts == 1
    assert delivery.last_error["reason"] == "missing_secret_env"
  end

  test "creates telegram binding records", %{room: room} do
    assert {:ok, binding} =
             Rooms.create_channel_binding(room, %{
               provider: "telegram",
               slug: "delivery-telegram",
               external_chat_id: "-1001",
               token_env: "TELEGRAM_BOT_TOKEN",
               secret_env: "TELEGRAM_WEBHOOK_SECRET"
             })

    assert binding.provider == "telegram"
    assert binding.external_chat_id == "-1001"
  end

  test "telegram test sends fail locally while chat capture is pending", %{room: room} do
    assert {:ok, binding} =
             Rooms.create_channel_binding(room, %{
               provider: "telegram",
               slug: "delivery-telegram-pending",
               external_chat_id: "pending:delivery-telegram-pending",
               token_env: "TELEGRAM_BOT_TOKEN",
               config: %{"capture_chat_id" => true}
             })

    assert {:error, %{"reason" => "telegram_chat_id_capture_pending"}} =
             Rooms.send_telegram_message(binding, "Hydra setup test")
  end

  test "telegram setup readiness exposes production blockers and webhook command", %{room: room} do
    previous_host = System.get_env("PHX_HOST")
    System.delete_env("PHX_HOST")
    System.delete_env("MISSING_TELEGRAM_TOKEN")

    try do
      assert {:ok, binding} =
               Rooms.create_channel_binding(room, %{
                 provider: "telegram",
                 slug: "delivery-telegram-readiness",
                 external_chat_id: "pending:delivery-telegram-readiness",
                 token_env: "MISSING_TELEGRAM_TOKEN",
                 config: %{"capture_chat_id" => true},
                 last_error: %{"reason" => "telegram_delivery_failed"}
               })

      readiness = Rooms.telegram_setup_readiness(binding)

      assert readiness["status"] == "needs_attention"
      assert readiness["capture_pending"] == true
      assert readiness["webhook_path"] == "/api/v1/telegram/delivery-telegram-readiness/webhook"
      assert readiness["webhook_url"] =~ "$PHX_HOST"
      assert readiness["set_webhook_command"] =~ "setWebhook"
      assert readiness["set_webhook_command"] =~ "MISSING_TELEGRAM_TOKEN"

      assert Enum.any?(
               readiness["items"],
               &(&1["label"] == "Public host" and &1["status"] == "warning")
             )

      assert Enum.any?(
               readiness["items"],
               &(&1["label"] == "Bot token" and &1["status"] == "error")
             )

      assert Enum.any?(
               readiness["items"],
               &(&1["label"] == "Last error" and &1["status"] == "error")
             )
    after
      if previous_host,
        do: System.put_env("PHX_HOST", previous_host),
        else: System.delete_env("PHX_HOST")
    end
  end
end
