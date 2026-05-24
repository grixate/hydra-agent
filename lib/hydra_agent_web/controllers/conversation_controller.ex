defmodule HydraAgentWeb.ConversationController do
  use HydraAgentWeb, :controller

  alias HydraAgent.{AgentChat, Runtime}

  def index(conn, %{"workspace_id" => workspace_id}) do
    conversations = Runtime.list_conversations(workspace_id)
    json(conn, %{data: Enum.map(conversations, &conversation_json/1)})
  end

  def show(conn, %{"id" => id}) do
    conversation = Runtime.get_conversation!(id)
    json(conn, %{data: conversation_json(conversation, include_turns: true)})
  end

  def create(conn, %{"workspace_id" => workspace_id, "agent_id" => agent_id} = params) do
    params =
      params
      |> Map.put("workspace_id", workspace_id)
      |> Map.put("agent_id", agent_id)

    create_conversation(conn, params)
  end

  def create(conn, params) do
    create_conversation(conn, params)
  end

  defp create_conversation(conn, params) do
    case Runtime.create_conversation(params) do
      {:ok, conversation} ->
        conn
        |> put_status(:created)
        |> json(%{data: conversation_json(conversation)})

      {:error, changeset} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{errors: errors_json(changeset)})
    end
  end

  def message(conn, %{"id" => id, "content" => content}) do
    conversation = Runtime.get_conversation!(id)

    case AgentChat.respond(conversation, content) do
      {:ok, response} ->
        json(conn, %{
          data: %{
            conversation: conversation_json(response.conversation, include_turns: true),
            assistant_turn: turn_json(response.assistant_turn),
            provider_response: response.provider_response
          }
        })

      {:error, error} when is_map(error) ->
        conn |> put_status(:bad_gateway) |> json(%{errors: error})

      {:error, changeset} ->
        conn |> put_status(:unprocessable_entity) |> json(%{errors: errors_json(changeset)})
    end
  end

  def stream_message(conn, %{"id" => id, "content" => content}) do
    conversation = Runtime.get_conversation!(id)

    case AgentChat.stream_respond(conversation, content) do
      {:ok, response} ->
        json(conn, %{
          data: %{
            conversation: conversation_json(response.conversation, include_turns: true),
            assistant_turn: turn_json(response.assistant_turn),
            provider_response: response.provider_response,
            streamed: true
          }
        })

      {:error, error} when is_map(error) ->
        conn |> put_status(:bad_gateway) |> json(%{errors: error})

      {:error, changeset} ->
        conn |> put_status(:unprocessable_entity) |> json(%{errors: errors_json(changeset)})
    end
  end

  defp conversation_json(conversation, opts \\ []) do
    base = %{
      id: conversation.id,
      workspace_id: conversation.workspace_id,
      agent_id: conversation.agent_id,
      title: conversation.title,
      channel: conversation.channel,
      status: conversation.status,
      metadata: conversation.metadata,
      last_message_at: conversation.last_message_at,
      inserted_at: conversation.inserted_at,
      updated_at: conversation.updated_at
    }

    if Keyword.get(opts, :include_turns, false) do
      Map.put(base, :turns, Enum.map(loaded_turns(conversation), &turn_json/1))
    else
      base
    end
  end

  defp loaded_turns(conversation) do
    if Ecto.assoc_loaded?(conversation.turns), do: conversation.turns, else: []
  end

  defp turn_json(turn) do
    %{
      id: turn.id,
      conversation_id: turn.conversation_id,
      run_id: turn.run_id,
      role: turn.role,
      kind: turn.kind,
      content: turn.content,
      metadata: turn.metadata,
      inserted_at: turn.inserted_at
    }
  end

  defp errors_json(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
      Enum.reduce(opts, message, fn {key, value}, acc ->
        String.replace(acc, "%{#{key}}", to_string(value))
      end)
    end)
  end
end
