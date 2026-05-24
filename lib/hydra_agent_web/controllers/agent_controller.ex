defmodule HydraAgentWeb.AgentController do
  use HydraAgentWeb, :controller

  alias HydraAgent.{AgentChat, AgentPack, Runtime}

  def index(conn, %{"workspace_id" => workspace_id}) do
    agents = Runtime.list_agents(workspace_id)
    json(conn, %{data: Enum.map(agents, &agent_json/1)})
  end

  def show(conn, %{"id" => id}) do
    agent = Runtime.get_agent!(id)
    json(conn, %{data: agent_json(agent)})
  end

  def export_pack(conn, %{"id" => id}) do
    agent = Runtime.get_agent!(id)
    json(conn, %{data: AgentPack.from_agent(agent)})
  end

  def create(conn, %{"workspace_id" => workspace_id, "agent_pack" => pack}) do
    import_pack(conn, %{"workspace_id" => workspace_id, "agent_pack" => pack})
  end

  def create(conn, params) do
    case Runtime.create_agent(params) do
      {:ok, agent} ->
        conn
        |> put_status(:created)
        |> json(%{data: agent_json(agent)})

      {:error, changeset} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{errors: errors_json(changeset)})
    end
  end

  def import_pack(conn, %{"workspace_id" => workspace_id, "agent_pack" => pack}) do
    case import_agent_pack(workspace_id, pack) do
      {:ok, agent} ->
        conn
        |> put_status(:created)
        |> json(%{data: agent_json(agent)})

      {:error, errors} when is_list(errors) ->
        conn |> put_status(:unprocessable_entity) |> json(%{errors: errors})

      {:error, changeset} ->
        conn |> put_status(:unprocessable_entity) |> json(%{errors: errors_json(changeset)})
    end
  end

  def import_pack(conn, %{"workspace_id" => workspace_id, "pack" => pack}) do
    import_pack(conn, %{"workspace_id" => workspace_id, "agent_pack" => pack})
  end

  def import_pack(conn, _params) do
    conn
    |> put_status(:bad_request)
    |> json(%{errors: %{"agent_pack" => ["is required"]}})
  end

  defp import_agent_pack(workspace_id, pack) do
    with {:ok, attrs} <- AgentPack.to_agent_attrs(pack, workspace_id) do
      Runtime.create_agent(attrs)
    end
  end

  def chat(conn, %{"id" => id, "content" => content} = params) do
    agent = Runtime.get_agent!(id)

    with {:ok, conversation} <-
           AgentChat.start_conversation(agent, %{
             title: params["title"] || "Agent chat",
             metadata: %{"created_from" => "agent_chat_endpoint"}
           }),
         {:ok, response} <- AgentChat.respond(conversation, content) do
      json(conn, %{
        data: %{
          conversation: conversation_json(response.conversation),
          assistant_turn: turn_json(response.assistant_turn),
          provider_response: response.provider_response
        }
      })
    else
      {:error, error} when is_map(error) ->
        conn |> put_status(:bad_gateway) |> json(%{errors: error})

      {:error, changeset} ->
        conn |> put_status(:unprocessable_entity) |> json(%{errors: errors_json(changeset)})
    end
  end

  defp agent_json(agent) do
    %{
      id: agent.id,
      workspace_id: agent.workspace_id,
      slug: agent.slug,
      name: agent.name,
      role: agent.role,
      status: agent.status,
      description: agent.description,
      model_route: agent.model_route,
      capability_profile: agent.capability_profile,
      memory_scopes: agent.memory_scopes,
      knowledge_scopes: agent.knowledge_scopes
    }
  end

  defp conversation_json(conversation) do
    %{
      id: conversation.id,
      workspace_id: conversation.workspace_id,
      agent_id: conversation.agent_id,
      title: conversation.title,
      channel: conversation.channel,
      status: conversation.status,
      last_message_at: conversation.last_message_at
    }
  end

  defp turn_json(turn) do
    %{
      id: turn.id,
      conversation_id: turn.conversation_id,
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
