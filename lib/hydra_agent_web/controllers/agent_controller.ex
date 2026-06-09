defmodule HydraAgentWeb.AgentController do
  use HydraAgentWeb, :controller

  alias HydraAgent.{AgentChat, AgentPack, Plugins, Runtime}

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

  def pack_schema(conn, _params) do
    json(conn, %{data: AgentPack.json_schema()})
  end

  def starter_packs(conn, %{"workspace_id" => workspace_id}) do
    packs = starter_pack_entries() ++ plugin_starter_pack_entries(workspace_id)
    json(conn, %{data: packs})
  end

  def starter_packs(conn, _params) do
    packs = starter_pack_entries()
    json(conn, %{data: packs})
  end

  defp starter_pack_entries do
    packs =
      AgentPack.builtin_packs()
      |> Enum.map(fn
        %{"status" => "valid", "path" => path, "pack" => pack} ->
          %{
            path: path,
            status: "valid",
            pack: starter_pack_json(pack)
          }

        %{"status" => "invalid", "path" => path, "errors" => errors} ->
          %{path: path, status: "invalid", errors: errors}
      end)

    packs
  end

  defp plugin_starter_pack_entries(workspace_id) do
    workspace_id
    |> Plugins.enabled_agent_packs()
    |> Enum.map(fn pack ->
      %{
        path: "plugin:#{get_in(pack, ["plugin", "installation_id"])}",
        status: "valid",
        source: "plugin",
        pack: starter_pack_json(pack)
      }
    end)
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

  def import_pack(conn, %{"workspace_id" => workspace_id, "agent_pack" => pack, "mode" => mode}) do
    case import_agent_pack(workspace_id, pack, mode) do
      {:ok, %{dry_run?: true} = result} ->
        json(conn, %{data: dry_run_json(result)})

      {:ok, agent} ->
        status = if mode == "update_existing", do: :ok, else: :created

        conn
        |> put_status(status)
        |> json(%{data: agent_json(agent)})

      {:error, {:agent_pack, details}} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{errors: AgentPack.error_messages(details), details: details})

      {:error, errors} when is_list(errors) ->
        conn |> put_status(:unprocessable_entity) |> json(%{errors: errors})

      {:error, %Ecto.Changeset{} = changeset} ->
        conn |> put_status(:unprocessable_entity) |> json(%{errors: errors_json(changeset)})

      {:error, errors} when is_map(errors) ->
        conn |> put_status(:unprocessable_entity) |> json(%{errors: errors})
    end
  end

  def import_pack(conn, %{"workspace_id" => workspace_id, "agent_pack" => pack}) do
    import_pack(conn, %{"workspace_id" => workspace_id, "agent_pack" => pack, "mode" => "create"})
  end

  def import_pack(conn, %{"workspace_id" => workspace_id, "pack" => pack}) do
    import_pack(conn, %{"workspace_id" => workspace_id, "agent_pack" => pack})
  end

  def import_pack(conn, _params) do
    conn
    |> put_status(:bad_request)
    |> json(%{errors: %{"agent_pack" => ["is required"]}})
  end

  defp import_agent_pack(workspace_id, pack, mode) do
    with {:ok, normalized} <- AgentPack.validate_details(pack, workspace_id: workspace_id),
         {:ok, attrs} <- AgentPack.to_agent_attrs(normalized, workspace_id) do
      existing = Runtime.get_agent_by_slug(workspace_id, attrs.slug)

      case mode do
        "dry_run" ->
          {:ok,
           %{
             dry_run?: true,
             mode: "dry_run",
             existing_agent_id: existing && existing.id,
             agent_attrs: attrs,
             agent_pack: normalized
           }}

        "update_existing" ->
          if existing do
            Runtime.update_agent(existing, attrs)
          else
            {:error, %{"agent_pack" => ["no existing agent with slug #{attrs.slug}"]}}
          end

        "clone" ->
          attrs
          |> Map.put(:slug, unique_clone_slug(workspace_id, attrs.slug))
          |> Map.update!(:name, &clone_name/1)
          |> Runtime.create_agent()

        "create" ->
          Runtime.create_agent(attrs)

        _mode ->
          {:error, %{"mode" => ["must be one of create, dry_run, update_existing, clone"]}}
      end
    else
      {:error, details} when is_list(details) -> {:error, {:agent_pack, details}}
      error -> error
    end
  end

  defp dry_run_json(result) do
    attrs = result.agent_attrs

    %{
      mode: result.mode,
      existing_agent_id: result.existing_agent_id,
      agent_pack: result.agent_pack,
      agent_attrs: %{
        workspace_id: attrs.workspace_id,
        slug: attrs.slug,
        name: attrs.name,
        role: attrs.role,
        description: attrs.description,
        system_prompt: attrs.system_prompt,
        model_route: attrs.model_route,
        capability_profile: attrs.capability_profile,
        memory_scopes: attrs.memory_scopes,
        knowledge_scopes: attrs.knowledge_scopes
      }
    }
  end

  defp unique_clone_slug(workspace_id, slug) do
    Stream.iterate(1, &(&1 + 1))
    |> Enum.find_value(fn index ->
      candidate = "#{slug}-copy-#{index}"
      if is_nil(Runtime.get_agent_by_slug(workspace_id, candidate)), do: candidate
    end)
  end

  defp clone_name(name), do: "#{name} Copy"

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

  defp starter_pack_json(pack) do
    %{
      slug: pack["slug"],
      name: pack["name"],
      role: pack["role"],
      description: pack["description"],
      tools: pack["tools"],
      tool_bundles: pack["tool_bundles"] || [],
      skills: pack["skills"],
      connector_requirements: pack["connector_requirements"] || [],
      automation_recipes: pack["automation_recipes"] || [],
      room_defaults: pack["room_defaults"] || %{},
      task_pack: pack["task_pack"],
      content_channels: pack["content_channels"] || [],
      delivery_targets: pack["delivery_targets"] || [],
      permissions: pack["permissions"],
      autonomy: pack["autonomy"],
      approval_policy: pack["approval_policy"]
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
