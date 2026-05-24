defmodule HydraAgentWeb.KnowledgeController do
  use HydraAgentWeb, :controller

  alias HydraAgent.Knowledge

  def seed_types(conn, %{"workspace_id" => workspace_id}) do
    results = Knowledge.seed_neutral_type_definitions(workspace_id)

    errors =
      results
      |> Enum.filter(&match?({:error, _changeset}, &1))
      |> Enum.map(fn {:error, changeset} -> errors_json(changeset) end)

    if errors == [] do
      definitions =
        Enum.map(results, fn {:ok, definition} -> type_definition_json(definition) end)

      json(conn, %{data: definitions})
    else
      conn
      |> put_status(:unprocessable_entity)
      |> json(%{errors: errors})
    end
  end

  def index(conn, %{"workspace_id" => workspace_id} = params) do
    nodes =
      case params["q"] do
        query when is_binary(query) and query != "" ->
          Knowledge.search_nodes(workspace_id, query)

        _ ->
          Knowledge.list_nodes(workspace_id,
            type_key: params["type_key"],
            status: params["status"]
          )
      end

    json(conn, %{data: Enum.map(nodes, &node_json/1)})
  end

  def create(conn, params) do
    case Knowledge.create_node(params) do
      {:ok, node} ->
        conn
        |> put_status(:created)
        |> json(%{data: node_json(node)})

      {:error, changeset} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{errors: errors_json(changeset)})
    end
  end

  def relationships(conn, %{"workspace_id" => workspace_id} = params) do
    relationships =
      Knowledge.list_relationships(workspace_id,
        type_key: params["type_key"]
      )

    json(conn, %{data: Enum.map(relationships, &relationship_json/1)})
  end

  def create_relationship(conn, params) do
    case Knowledge.create_relationship(params) do
      {:ok, relationship} ->
        conn
        |> put_status(:created)
        |> json(%{data: relationship_json(relationship)})

      {:error, changeset} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{errors: errors_json(changeset)})
    end
  end

  defp node_json(node) do
    %{
      id: node.id,
      workspace_id: node.workspace_id,
      type_key: node.type_key,
      title: node.title,
      body: node.body,
      status: node.status,
      attributes: node.attributes,
      importance: node.importance,
      confidence: node.confidence,
      provenance: node.provenance,
      created_by_agent_id: node.created_by_agent_id
    }
  end

  defp relationship_json(relationship) do
    %{
      id: relationship.id,
      workspace_id: relationship.workspace_id,
      from_node_id: relationship.from_node_id,
      to_node_id: relationship.to_node_id,
      type_key: relationship.type_key,
      attributes: relationship.attributes,
      confidence: relationship.confidence,
      provenance: relationship.provenance,
      created_by_agent_id: relationship.created_by_agent_id
    }
  end

  defp type_definition_json(definition) do
    %{
      id: definition.id,
      workspace_id: definition.workspace_id,
      kind: definition.kind,
      type_key: definition.type_key,
      display_name: definition.display_name,
      description: definition.description,
      extends: definition.extends,
      attribute_schema: definition.attribute_schema,
      status_vocabulary: definition.status_vocabulary,
      metadata: definition.metadata
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
