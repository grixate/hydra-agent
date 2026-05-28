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

  def create(conn, %{"workspace_id" => workspace_id} = params) do
    do_create(conn, Map.put(params, "workspace_id", workspace_id))
  end

  def create(conn, params) do
    do_create(conn, params)
  end

  defp do_create(conn, params) do
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

  def show(conn, %{"workspace_id" => workspace_id, "id" => id}) do
    node = Knowledge.get_node_detail_for_workspace!(workspace_id, id)
    json(conn, %{data: node_json(node)})
  end

  def show(conn, %{"id" => id}) do
    node = Knowledge.get_node_detail!(id)
    json(conn, %{data: node_json(node)})
  end

  def relationships(conn, %{"workspace_id" => workspace_id} = params) do
    relationships =
      Knowledge.list_relationships(workspace_id,
        type_key: params["type_key"]
      )

    json(conn, %{data: Enum.map(relationships, &relationship_json/1)})
  end

  def create_relationship(conn, %{"workspace_id" => workspace_id} = params) do
    do_create_relationship(conn, Map.put(params, "workspace_id", workspace_id))
  end

  def create_relationship(conn, params) do
    do_create_relationship(conn, params)
  end

  defp do_create_relationship(conn, params) do
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

  def show_relationship(conn, %{"workspace_id" => workspace_id, "id" => id}) do
    relationship = Knowledge.get_relationship_detail_for_workspace!(workspace_id, id)
    json(conn, %{data: relationship_json(relationship)})
  end

  def show_relationship(conn, %{"id" => id}) do
    relationship = Knowledge.get_relationship_detail!(id)
    json(conn, %{data: relationship_json(relationship)})
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
      created_by_agent_id: node.created_by_agent_id,
      outgoing_relationships:
        Enum.map(
          (Ecto.assoc_loaded?(node.outgoing_relationships) && node.outgoing_relationships) || [],
          &relationship_json/1
        ),
      incoming_relationships:
        Enum.map(
          (Ecto.assoc_loaded?(node.incoming_relationships) && node.incoming_relationships) || [],
          &relationship_json/1
        )
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
      created_by_agent_id: relationship.created_by_agent_id,
      from_node: assoc_json(relationship, :from_node, &node_ref_json/1),
      to_node: assoc_json(relationship, :to_node, &node_ref_json/1)
    }
  end

  defp node_ref_json(node) do
    %{
      id: node.id,
      type_key: node.type_key,
      title: node.title,
      status: node.status
    }
  end

  defp assoc_json(parent, assoc, mapper) do
    value = Map.get(parent, assoc)

    if Ecto.assoc_loaded?(value) and value do
      mapper.(value)
    end
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
