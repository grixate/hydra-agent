defmodule HydraAgentWeb.TelegramControllerTest do
  use HydraAgentWeb.ConnCase, async: false

  import HydraAgent.RuntimeFixtures

  alias HydraAgent.{Rooms, Runtime}

  setup do
    previous_secret = System.get_env("HYDRA_TELEGRAM_TEST_SECRET")
    previous_api_token = System.get_env("HYDRA_TELEGRAM_GATEWAY_API_TOKEN")
    previous_api_auth = Application.get_env(:hydra_agent, :api_auth)
    System.put_env("HYDRA_TELEGRAM_TEST_SECRET", "telegram-test-secret")
    System.put_env("HYDRA_TELEGRAM_GATEWAY_API_TOKEN", "different-global-api-token")

    Application.put_env(:hydra_agent, :api_auth,
      enabled?: true,
      token_env: "HYDRA_TELEGRAM_GATEWAY_API_TOKEN"
    )

    on_exit(fn ->
      restore_env("HYDRA_TELEGRAM_TEST_SECRET", previous_secret)
      restore_env("HYDRA_TELEGRAM_GATEWAY_API_TOKEN", previous_api_token)

      if previous_api_auth,
        do: Application.put_env(:hydra_agent, :api_auth, previous_api_auth),
        else: Application.delete_env(:hydra_agent, :api_auth)
    end)

    :ok
  end

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
        external_chat_id: "-10042",
        secret_env: "HYDRA_TELEGRAM_TEST_SECRET"
      })

    conn =
      conn
      |> put_req_header("x-telegram-bot-api-secret-token", "telegram-test-secret")
      |> post(~p"/api/v1/telegram/telegram-room-binding/webhook", %{
        update_id: 123,
        message: %{
          message_id: 456,
          chat: %{id: -10042},
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
      build_conn()
      |> put_req_header("x-telegram-bot-api-secret-token", "telegram-test-secret")
      |> post(~p"/api/v1/telegram/telegram-room-binding/webhook", %{
        update_id: 123,
        message: %{
          message_id: 456,
          chat: %{id: -10042},
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
        secret_env: "HYDRA_TELEGRAM_TEST_SECRET",
        config: %{"capture_chat_id" => true}
      })

    conn =
      conn
      |> put_req_header("x-telegram-bot-api-secret-token", "telegram-test-secret")
      |> post(~p"/api/v1/telegram/telegram-capture-binding/webhook", %{
        update_id: 789,
        message: %{
          message_id: 101,
          chat: %{id: -20042},
          text: "capture me"
        }
      })

    assert %{"data" => %{"agent_message_ids" => [_]}} = json_response(conn, 200)

    [binding] = Rooms.list_channel_bindings(Rooms.get_room!(room.id))
    assert binding.external_chat_id == "-20042"
    assert binding.config["capture_chat_id"] == false
  end

  test "telegram webhook fails closed without a configured binding secret", %{conn: conn} do
    workspace = workspace_fixture(%{name: "Ops", slug: "ops-telegram-missing-secret"})
    agent = agent_fixture(workspace, %{slug: "telegram-missing-secret-agent"})

    {:ok, room} =
      Rooms.create_room(%{
        workspace_id: workspace.id,
        title: "Missing Secret Room",
        slug: "missing-secret-room",
        coordinator_agent_id: agent.id
      })

    {:ok, _binding} =
      Rooms.create_channel_binding(room, %{
        provider: "telegram",
        slug: "telegram-missing-secret-binding",
        external_chat_id: "-30042"
      })

    response =
      post(conn, ~p"/api/v1/telegram/telegram-missing-secret-binding/webhook", %{
        update_id: 999,
        message: %{message_id: 202, chat: %{id: -30042}, text: "must be rejected"}
      })

    assert %{"errors" => %{"reason" => "missing_telegram_secret_env"}} =
             json_response(response, 503)

    assert Rooms.get_room!(room.id) |> Rooms.list_messages() == []
  end

  defp restore_env(name, nil), do: System.delete_env(name)
  defp restore_env(name, value), do: System.put_env(name, value)
end
