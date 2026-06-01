defmodule HydraAgentWeb.ConversationControllerTest do
  use HydraAgentWeb.ConnCase

  import HydraAgent.RuntimeFixtures

  alias HydraAgent.{AgentChat, Runtime, Usage}

  test "POST /api/v1/conversations/:id/stream returns streamed response and durable turns", %{
    conn: conn
  } do
    %{agent: agent, workspace: workspace} =
      runtime_fixture(%{
        agent: %{model_route: %{"default_provider" => "mock"}}
      })

    {:ok, _provider} =
      Runtime.create_provider(%{
        workspace_id: workspace.id,
        name: "mock",
        kind: "mock",
        model: "mock-1"
      })

    {:ok, conversation} = AgentChat.start_conversation(agent)

    conn = post(conn, ~p"/api/v1/conversations/#{conversation.id}/stream", %{content: "hello"})
    response = json_response(conn, 200)["data"]

    assert response["streamed"] == true
    assert response["assistant_turn"]["content"] == "mock: hello"
    assert response["provider_response"]["message"]["content"] == "mock: hello"

    conversation = Runtime.get_conversation!(conversation.id)
    assert Enum.map(conversation.turns, & &1.role) == ["user", "assistant"]
    assert [%{status: "ok"}] = Usage.list_records(workspace.id)
  end

  test "POST /api/v1/conversations/:id/stream returns provider error without assistant turn", %{
    conn: conn
  } do
    workspace = workspace_fixture()
    agent = agent_fixture(workspace, %{model_route: %{"default_provider" => "openai"}})

    {:ok, _provider} =
      Runtime.create_provider(%{
        workspace_id: workspace.id,
        name: "openai",
        kind: "openai_compatible",
        model: "gpt-test",
        api_key_env: "HYDRA_TEST_STREAM_CONTROLLER_MISSING"
      })

    {:ok, conversation} = AgentChat.start_conversation(agent)

    conn = post(conn, ~p"/api/v1/conversations/#{conversation.id}/stream", %{content: "hello"})
    response = json_response(conn, 502)

    assert response["errors"]["reason"] == "all_providers_failed"

    conversation = Runtime.get_conversation!(conversation.id)
    assert Enum.map(conversation.turns, & &1.role) == ["user"]
    assert [%{status: "error"}] = Usage.list_records(workspace.id)
  end
end
