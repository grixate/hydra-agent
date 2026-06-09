defmodule HydraAgentWeb.TelegramControllerTest do
  use HydraAgentWeb.ConnCase

  import HydraAgent.RuntimeFixtures

  alias HydraAgent.{Rooms, Runtime}

  test "telegram webhook maps a chat update into a room message", %{conn: conn} do
    workspace = workspace_fixture(%{name: "Ops", slug: "ops-telegram-room"})

    {:ok, _provider} =
      Runtime.create_provider(%{
        workspace_id: workspace.id,
        name: "mock",
        kind: "mock",
        model: "mock-model"
      })

    agent =
      agent_fixture(workspace, %{
        name: "Telegram Agent",
        slug: "telegram-agent",
        model_route: %{"default_provider" => "mock"}
      })

    {:ok, room} =
      Rooms.create_room(%{
        workspace_id: workspace.id,
        title: "Telegram Room",
        slug: "telegram-room",
        coordinator_agent_id: agent.id
      })

    {:ok, _binding} =
      Rooms.create_channel_binding(room, %{
        provider: "telegram",
        slug: "telegram-room-binding",
        external_chat_id: "-10042"
      })

    conn =
      post(conn, ~p"/api/v1/telegram/telegram-room-binding/webhook", %{
        update_id: 123,
        message: %{
          message_id: 456,
          chat: %{id: -10_042},
          text: "hello from telegram"
        }
      })

    assert %{"data" => %{"agent_message_ids" => [_]}} = json_response(conn, 200)

    messages = Rooms.get_room!(room.id) |> Rooms.list_messages()
    assert Enum.map(messages, & &1.source_channel) == ["telegram", "telegram"]

    assert Enum.map(messages, & &1.content) == [
             "hello from telegram",
             "mock: hello from telegram"
           ]

    [binding] = Rooms.list_channel_bindings(Rooms.get_room!(room.id))
    assert binding.last_received_at
    assert binding.last_error["reason"] == "telegram_delivery_failed"

    conn =
      post(build_conn(), ~p"/api/v1/telegram/telegram-room-binding/webhook", %{
        update_id: 123,
        message: %{
          message_id: 456,
          chat: %{id: -10_042},
          text: "hello from telegram"
        }
      })

    assert %{"data" => %{"agent_message_ids" => []}} = json_response(conn, 200)

    messages = Rooms.get_room!(room.id) |> Rooms.list_messages()
    assert length(messages) == 2
  end

  test "telegram webhook can capture a pending chat id", %{conn: conn} do
    workspace = workspace_fixture(%{name: "Ops", slug: "ops-telegram-capture"})

    {:ok, _provider} =
      Runtime.create_provider(%{
        workspace_id: workspace.id,
        name: "mock",
        kind: "mock",
        model: "mock-model"
      })

    agent =
      agent_fixture(workspace, %{
        name: "Capture Agent",
        slug: "capture-agent",
        model_route: %{"default_provider" => "mock"}
      })

    {:ok, room} =
      Rooms.create_room(%{
        workspace_id: workspace.id,
        title: "Capture Room",
        slug: "capture-room",
        coordinator_agent_id: agent.id
      })

    {:ok, _binding} =
      Rooms.create_channel_binding(room, %{
        provider: "telegram",
        slug: "telegram-capture-binding",
        external_chat_id: "pending:telegram-capture-binding",
        config: %{"capture_chat_id" => true}
      })

    conn =
      post(conn, ~p"/api/v1/telegram/telegram-capture-binding/webhook", %{
        update_id: 789,
        message: %{
          message_id: 101,
          chat: %{id: -20_042},
          text: "capture me"
        }
      })

    assert %{"data" => %{"agent_message_ids" => [_]}} = json_response(conn, 200)

    [binding] = Rooms.list_channel_bindings(Rooms.get_room!(room.id))
    assert binding.external_chat_id == "-20042"
    assert binding.config["capture_chat_id"] == false
  end
end
