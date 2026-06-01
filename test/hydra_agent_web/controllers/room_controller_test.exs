defmodule HydraAgentWeb.RoomControllerTest do
  use HydraAgentWeb.ConnCase

  import HydraAgent.RuntimeFixtures

  alias HydraAgent.Runtime

  setup do
    workspace = workspace_fixture(%{name: "Ops", slug: "ops-room-api"})

    {:ok, _provider} =
      Runtime.create_provider(%{
        workspace_id: workspace.id,
        name: "mock",
        kind: "mock",
        model: "mock-model"
      })

    agent =
      agent_fixture(workspace, %{
        name: "Room Coordinator",
        slug: "room-coordinator",
        model_route: %{"default_provider" => "mock"}
      })

    {:ok, workspace: workspace, agent: agent}
  end

  test "creates rooms, members, messages, and bindings through workspace API", %{
    conn: conn,
    workspace: workspace,
    agent: agent
  } do
    conn =
      post(conn, ~p"/api/v1/workspaces/#{workspace.id}/rooms", %{
        title: "Ops Room",
        slug: "ops-room",
        coordinator_agent_id: agent.id
      })

    assert %{"data" => %{"id" => room_id, "members" => [%{"agent_id" => agent_id}]}} =
             json_response(conn, 201)

    assert agent_id == agent.id

    conn =
      post(build_conn(), ~p"/api/v1/workspaces/#{workspace.id}/rooms/#{room_id}/messages", %{
        content: "status please"
      })

    assert %{
             "data" => %{
               "user_message" => %{"content" => "status please"},
               "agent_messages" => [%{"content" => "mock: status please"}]
             }
           } = json_response(conn, 200)

    conn =
      post(
        build_conn(),
        ~p"/api/v1/workspaces/#{workspace.id}/rooms/#{room_id}/channel_bindings",
        %{
          provider: "telegram",
          slug: "ops-room-telegram",
          external_chat_id: "-100123",
          token_env: "TELEGRAM_BOT_TOKEN"
        }
      )

    assert %{
             "data" => %{
               "provider" => "telegram",
               "token_ref" => "env:TELEGRAM_BOT_TOKEN",
               "telegram_setup" => %{
                 "status" => "needs_attention",
                 "webhook_path" => "/api/v1/telegram/ops-room-telegram/webhook"
               }
             }
           } =
             json_response(conn, 201)

    conn =
      get(
        build_conn(),
        ~p"/api/v1/workspaces/#{workspace.id}/rooms/#{room_id}/transcript"
      )

    assert %{"data" => %{"messages" => [%{"content" => "status please"}, _reply]}} =
             json_response(conn, 200)
  end

  test "approves pending room proposals through workspace API", %{
    conn: conn,
    workspace: workspace,
    agent: coordinator
  } do
    reviewer =
      agent_fixture(workspace, %{
        name: "Room Reviewer",
        slug: "room-reviewer",
        model_route: %{"default_provider" => "mock"}
      })

    conn =
      post(conn, ~p"/api/v1/workspaces/#{workspace.id}/rooms", %{
        title: "Approval Room",
        slug: "approval-room",
        coordinator_agent_id: coordinator.id
      })

    %{"data" => %{"id" => room_id}} = json_response(conn, 201)

    post(
      build_conn(),
      ~p"/api/v1/workspaces/#{workspace.id}/rooms/#{room_id}/members",
      %{
        agent_id: reviewer.id,
        mention_handle: "reviewer"
      }
    )

    conn =
      post(build_conn(), ~p"/api/v1/workspaces/#{workspace.id}/rooms/#{room_id}/messages", %{
        content: "@room-coordinator @reviewer compare"
      })

    %{"data" => %{"pending_proposal" => %{"id" => proposal_id}}} = json_response(conn, 200)

    conn =
      post(
        build_conn(),
        ~p"/api/v1/workspaces/#{workspace.id}/rooms/#{room_id}/messages/#{proposal_id}/approve",
        %{}
      )

    assert %{
             "data" => %{
               "proposal" => %{
                 "metadata" => %{"proposal_status" => "approved_multi_agent_response"}
               },
               "agent_messages" => [
                 %{"content" => "mock: @room-coordinator @reviewer compare"},
                 %{"content" => "mock: @room-coordinator @reviewer compare"}
               ]
             }
           } = json_response(conn, 200)
  end

  test "agent builder API creates an agent and policy", %{conn: conn, workspace: workspace} do
    conn =
      post(conn, ~p"/api/v1/workspaces/#{workspace.id}/agent_builder/create", %{
        preset: "researcher",
        name: "Research Lead",
        default_provider: "mock"
      })

    assert %{
             "data" => %{
               "agent" => %{"slug" => "research-lead"},
               "policy" => %{"requires_approval" => true}
             }
           } = json_response(conn, 201)
  end
end
