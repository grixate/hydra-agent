defmodule HydraAgent.AgentChatTest do
  use ExUnit.Case, async: true

  alias HydraAgent.AgentChat
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
end
