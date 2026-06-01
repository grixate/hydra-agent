defmodule HydraAgent.AgentChatTest do
  use HydraAgent.DataCase

  import HydraAgent.RuntimeFixtures

  alias HydraAgent.{AgentChat, Runtime, Safety, Usage}
  alias HydraAgent.Runtime.{AgentProfile, Conversation}

  test "build_request includes system prompt and current user message" do
    agent = %AgentProfile{
      id: 1,
      workspace_id: 1,
      system_prompt: "Be precise.",
      knowledge_scopes: []
    }

    conversation = %Conversation{id: 1, agent: agent, turns: []}

    request =
      AgentChat.build_request(conversation, agent, "Summarize the runtime.", memory_limit: 0)

    assert [%{"role" => "system", "content" => system}, %{"role" => "user", "content" => content}] =
             request["messages"]

    assert system =~ "Be precise."
    assert content == "Summarize the runtime."
    assert request["metadata"]["memory"]["count"] == 0
  end

  test "build_request preserves recent user and assistant turns" do
    agent = %AgentProfile{
      id: 1,
      workspace_id: 1,
      system_prompt: "Be precise.",
      knowledge_scopes: []
    }

    conversation = %Conversation{
      id: 1,
      agent: agent,
      turns: [
        %{kind: "message", role: "user", content: "one"},
        %{kind: "message", role: "assistant", content: "two"},
        %{kind: "summary", role: "system", content: "ignored"}
      ]
    }

    request =
      AgentChat.build_request(conversation, agent, "three", history_limit: 2, memory_limit: 0)

    assert Enum.map(request["messages"], & &1["content"]) == [
             "Be precise.",
             "one",
             "two",
             "three"
           ]
  end

  test "stream_respond persists one assistant turn and records usage once" do
    %{agent: agent, workspace: workspace} =
      runtime_fixture(%{
        agent: %{
          model_route: %{"default_provider" => "mock"}
        }
      })

    {:ok, _provider} =
      Runtime.create_provider(%{
        workspace_id: workspace.id,
        name: "mock",
        kind: "mock",
        model: "mock-1"
      })

    {:ok, conversation} = AgentChat.start_conversation(agent)
    parent = self()

    assert {:ok, result} =
             AgentChat.stream_respond(conversation, "stream contract",
               memory_limit: 0,
               on_delta: fn delta -> send(parent, {:delta, delta}) end
             )

    assert result.assistant_turn.content == "mock: stream contract"

    conversation = Runtime.get_conversation!(conversation.id)
    assistant_turns = Enum.filter(conversation.turns, &(&1.role == "assistant"))

    assert length(assistant_turns) == 1
    assert hd(assistant_turns).metadata["streamed"] == true

    assert [%{status: "ok", conversation_id: conversation_id, turn_id: turn_id}] =
             Usage.list_records(workspace.id)

    assert conversation_id == conversation.id
    assert turn_id == hd(assistant_turns).id

    assert_receive {:delta, %{"type" => "message.delta", "content" => "mock: stream contract"}}

    assert_receive {:delta,
                    %{"type" => "message.completed", "content" => "mock: stream contract"}}
  end

  test "stream_respond records provider errors without assistant turn" do
    workspace = workspace_fixture()

    agent =
      agent_fixture(workspace, %{
        model_route: %{"default_provider" => "missing-secret-provider"}
      })

    {:ok, _provider} =
      Runtime.create_provider(%{
        workspace_id: workspace.id,
        name: "missing-secret-provider",
        kind: "openai_compatible",
        model: "gpt-test",
        api_key_env: "HYDRA_TEST_MISSING_STREAM_KEY"
      })

    {:ok, conversation} = AgentChat.start_conversation(agent)

    assert {:error, %{"reason" => "all_providers_failed"}} =
             AgentChat.stream_respond(conversation, "fail cleanly", memory_limit: 0)

    conversation = Runtime.get_conversation!(conversation.id)
    assert Enum.map(conversation.turns, & &1.role) == ["user"]

    assert [%{status: "error", conversation_id: conversation_id}] =
             Usage.list_records(workspace.id)

    assert conversation_id == conversation.id

    assert [%{action: "agent_chat_failed", category: "provider"}] =
             Safety.list_events(workspace.id)
  end
end
