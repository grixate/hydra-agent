defmodule HydraAgent.AgentChat do
  @moduledoc """
  Provider-backed agent chat with durable turns and workspace memory recall.
  """

  alias HydraAgent.{Budgets, Memory, Providers, Runtime, Safety, Usage}
  alias HydraAgent.Runtime.{AgentProfile, Conversation}

  def respond(%Conversation{} = conversation, content, opts \\ []) when is_binary(content) do
    conversation = Runtime.get_conversation!(conversation.id)
    agent = conversation.agent
    usage_category = Keyword.get(opts, :usage_category, "chat")

    with {:ok, user_turn} <-
           Runtime.append_turn(conversation, %{
             run_id: Keyword.get(opts, :run_id),
             role: "user",
             kind: "message",
             content: content,
             metadata: %{"source" => Keyword.get(opts, :source, "api")}
           }),
         request <- build_request(conversation, agent, content, opts),
         :ok <-
           Budgets.check_available(conversation.workspace_id,
             agent_id: agent.id,
             category: usage_category
           ),
         {:ok, provider_response} <- Providers.chat(agent, request),
         {:ok, assistant_turn} <-
           Runtime.append_turn(conversation, %{
             run_id: Keyword.get(opts, :run_id),
             role: "assistant",
             kind: "message",
             content: get_in(provider_response, ["message", "content"]) || "",
             metadata: %{
               "provider" => provider_response["provider"],
               "model" => provider_response["model"],
               "usage" => provider_response["usage"],
               "memory" => request["metadata"]["memory"]
             }
           }) do
      Usage.record_provider_response(
        %{
          workspace_id: conversation.workspace_id,
          agent_id: agent.id,
          run_id: Keyword.get(opts, :run_id),
          conversation_id: conversation.id,
          turn_id: assistant_turn.id
        },
        provider_response,
        usage_category
      )

      {:ok,
       %{
         conversation: Runtime.get_conversation!(conversation.id),
         user_turn: user_turn,
         assistant_turn: assistant_turn,
         provider_response: provider_response
       }}
    else
      {:error, error} when is_map(error) ->
        record_error_event(conversation, agent, error)

        Usage.record_error(
          %{
            workspace_id: conversation.workspace_id,
            agent_id: agent.id,
            run_id: Keyword.get(opts, :run_id),
            conversation_id: conversation.id
          },
          error,
          usage_category
        )

        {:error, error}

      {:error, changeset} ->
        {:error, changeset}
    end
  end

  def stream_respond(%Conversation{} = conversation, content, opts \\ [])
      when is_binary(content) do
    conversation = Runtime.get_conversation!(conversation.id)
    agent = conversation.agent
    usage_category = Keyword.get(opts, :usage_category, "chat")
    on_delta = Keyword.get(opts, :on_delta, fn _delta -> :ok end)

    with {:ok, user_turn} <-
           Runtime.append_turn(conversation, %{
             run_id: Keyword.get(opts, :run_id),
             role: "user",
             kind: "message",
             content: content,
             metadata: %{"source" => Keyword.get(opts, :source, "api_stream")}
           }),
         request <- build_request(conversation, agent, content, opts),
         :ok <-
           Budgets.check_available(conversation.workspace_id,
             agent_id: agent.id,
             category: usage_category
           ),
         {:ok, provider_response} <-
           Providers.stream_chat(agent, request, fn delta ->
             delta = normalize_delta(delta, conversation, agent)
             HydraAgent.Runtime.PubSub.broadcast_conversation_delta(conversation, delta)
             on_delta.(delta)
           end),
         {:ok, assistant_turn} <-
           Runtime.append_turn(conversation, %{
             run_id: Keyword.get(opts, :run_id),
             role: "assistant",
             kind: "message",
             content: get_in(provider_response, ["message", "content"]) || "",
             metadata: %{
               "provider" => provider_response["provider"],
               "model" => provider_response["model"],
               "usage" => provider_response["usage"],
               "memory" => request["metadata"]["memory"],
               "streamed" => true
             }
           }) do
      Usage.record_provider_response(
        %{
          workspace_id: conversation.workspace_id,
          agent_id: agent.id,
          run_id: Keyword.get(opts, :run_id),
          conversation_id: conversation.id,
          turn_id: assistant_turn.id
        },
        provider_response,
        usage_category
      )

      final_delta =
        normalize_delta(
          %{
            "type" => "message.completed",
            "turn_id" => assistant_turn.id,
            "content" => assistant_turn.content
          },
          conversation,
          agent
        )

      HydraAgent.Runtime.PubSub.broadcast_conversation_delta(conversation, final_delta)
      on_delta.(final_delta)

      {:ok,
       %{
         conversation: Runtime.get_conversation!(conversation.id),
         user_turn: user_turn,
         assistant_turn: assistant_turn,
         provider_response: provider_response
       }}
    else
      {:error, error} when is_map(error) ->
        record_error_event(conversation, agent, error)

        Usage.record_error(
          %{
            workspace_id: conversation.workspace_id,
            agent_id: agent.id,
            run_id: Keyword.get(opts, :run_id),
            conversation_id: conversation.id
          },
          error,
          usage_category
        )

        {:error, error}

      {:error, changeset} ->
        {:error, changeset}
    end
  end

  def start_conversation(%AgentProfile{} = agent, attrs \\ %{}) do
    attrs =
      attrs
      |> stringify_keys()
      |> Map.put_new("workspace_id", agent.workspace_id)
      |> Map.put_new("agent_id", agent.id)
      |> Map.put_new("channel", "control_plane")

    Runtime.create_conversation(attrs)
  end

  def build_request(%Conversation{} = conversation, %AgentProfile{} = agent, content, opts \\ []) do
    memory = recall_memory(agent, content, Keyword.get(opts, :memory_limit, 6))
    memory_context = Memory.format_context(memory)

    system_content =
      [agent.system_prompt || "", memory_system_context(memory_context)]
      |> Enum.reject(&(&1 == ""))
      |> Enum.join("\n\n")

    messages =
      []
      |> maybe_add_system(system_content)
      |> Kernel.++(history_messages(conversation, Keyword.get(opts, :history_limit, 12)))
      |> Kernel.++([%{"role" => "user", "content" => content}])

    %{
      "messages" => messages,
      "temperature" => Keyword.get(opts, :temperature),
      "max_tokens" => Keyword.get(opts, :max_tokens),
      "metadata" => %{"memory" => memory}
    }
  end

  defp history_messages(%Conversation{} = conversation, limit) do
    turns =
      if Ecto.assoc_loaded?(conversation.turns) do
        conversation.turns
      else
        Runtime.list_turns(conversation.id)
      end

    turns
    |> Enum.filter(&(&1.kind == "message" and &1.role in ~w(user assistant)))
    |> Enum.take(-limit)
    |> Enum.map(&%{"role" => &1.role, "content" => &1.content})
  end

  defp maybe_add_system(messages, ""), do: messages

  defp maybe_add_system(messages, content),
    do: messages ++ [%{"role" => "system", "content" => content}]

  defp recall_memory(_agent, query, 0), do: %{"query" => query, "nodes" => [], "count" => 0}
  defp recall_memory(agent, query, limit), do: Memory.recall(agent, query, limit: limit)

  defp memory_system_context(""), do: ""

  defp memory_system_context(memory_context) do
    "Relevant workspace memory:\n#{memory_context}"
  end

  defp normalize_delta(delta, conversation, agent) when is_map(delta) do
    delta
    |> stringify_keys()
    |> Map.put_new("conversation_id", conversation.id)
    |> Map.put_new("workspace_id", conversation.workspace_id)
    |> Map.put_new("agent_id", agent.id)
    |> Map.put_new(
      "inserted_at",
      DateTime.utc_now() |> DateTime.truncate(:microsecond) |> DateTime.to_iso8601()
    )
  end

  defp record_error_event(conversation, agent, %{"reason" => "budget_exceeded"} = error) do
    Safety.record_event(%{
      workspace_id: conversation.workspace_id,
      agent_id: agent.id,
      category: "runtime",
      severity: "warning",
      action: "agent_chat_budget_exceeded",
      summary: "Agent chat blocked by budget",
      metadata: error
    })
  end

  defp record_error_event(conversation, agent, error) do
    Safety.record_event(%{
      workspace_id: conversation.workspace_id,
      agent_id: agent.id,
      category: "provider",
      severity: "warning",
      action: "agent_chat_failed",
      summary: "Agent chat provider call failed",
      metadata: error
    })
  end

  defp stringify_keys(map) when is_map(map),
    do: Map.new(map, fn {key, value} -> {to_string(key), value} end)
end
