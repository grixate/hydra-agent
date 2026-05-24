defmodule HydraAgent.Knowledge do
  @moduledoc """
  Workspace-scoped knowledge graph for memories, evidence, artifacts, and run context.
  """

  import Ecto.Query

  alias HydraAgent.Knowledge.{Node, Relationship, TypeDefinition}
  alias HydraAgent.Repo

  @neutral_type_definitions [
    %{
      "kind" => "node",
      "type_key" => "source",
      "display_name" => "Source",
      "description" => "External or local material used as evidence.",
      "status_vocabulary" => ["active", "verified", "archived"]
    },
    %{
      "kind" => "node",
      "type_key" => "artifact",
      "display_name" => "Artifact",
      "description" => "A file, report, patch, generated output, or durable deliverable.",
      "status_vocabulary" => ["draft", "active", "verified", "archived"]
    },
    %{
      "kind" => "node",
      "type_key" => "claim",
      "display_name" => "Claim",
      "description" => "A source-grounded assertion with confidence and provenance.",
      "status_vocabulary" => ["draft", "active", "verified", "conflicted", "superseded"]
    },
    %{
      "kind" => "node",
      "type_key" => "observation",
      "display_name" => "Observation",
      "description" => "A raw noticed fact or datum before it is promoted to a claim.",
      "status_vocabulary" => ["draft", "active", "verified", "archived"]
    },
    %{
      "kind" => "node",
      "type_key" => "entity",
      "display_name" => "Entity",
      "description" =>
        "A person, organization, repository, service, system, or other named object.",
      "status_vocabulary" => ["draft", "active", "verified", "archived"]
    },
    %{
      "kind" => "node",
      "type_key" => "event",
      "display_name" => "Event",
      "description" =>
        "Something that happened in the runtime, workspace, or an external system.",
      "status_vocabulary" => ["draft", "active", "verified", "archived"]
    },
    %{
      "kind" => "node",
      "type_key" => "decision",
      "display_name" => "Decision",
      "description" => "A durable operator or agent decision and its rationale.",
      "status_vocabulary" => ["draft", "active", "superseded", "archived"]
    },
    %{
      "kind" => "node",
      "type_key" => "task",
      "display_name" => "Task",
      "description" =>
        "A discovered follow-up or external work item. Durable execution state remains in RunStep.",
      "status_vocabulary" => ["draft", "active", "completed", "archived"]
    },
    %{
      "kind" => "node",
      "type_key" => "risk",
      "display_name" => "Risk",
      "description" => "Potential failure, security issue, assumption, or operational concern.",
      "status_vocabulary" => ["draft", "active", "verified", "superseded", "archived"]
    },
    %{
      "kind" => "node",
      "type_key" => "memory",
      "display_name" => "Memory",
      "description" => "Reusable workspace knowledge for future agent context.",
      "status_vocabulary" => ["draft", "active", "verified", "archived"]
    },
    %{
      "kind" => "relationship",
      "type_key" => "references",
      "display_name" => "References",
      "description" => "Connects a node to a source or artifact it cites."
    },
    %{
      "kind" => "relationship",
      "type_key" => "supports",
      "display_name" => "Supports",
      "description" => "Connects evidence or sources to a supported claim."
    },
    %{
      "kind" => "relationship",
      "type_key" => "contradicts",
      "display_name" => "Contradicts",
      "description" => "Connects evidence or claims that are in tension."
    },
    %{
      "kind" => "relationship",
      "type_key" => "derived_from",
      "display_name" => "Derived From",
      "description" =>
        "Connects a node to the source, observation, or artifact it was derived from."
    },
    %{
      "kind" => "relationship",
      "type_key" => "produced_by",
      "display_name" => "Produced By",
      "description" => "Connects a run, task, or agent output to an artifact."
    },
    %{
      "kind" => "relationship",
      "type_key" => "depends_on",
      "display_name" => "Depends On",
      "description" => "Connects tasks, decisions, or artifacts with dependencies."
    },
    %{
      "kind" => "relationship",
      "type_key" => "relates_to",
      "display_name" => "Relates To",
      "description" => "Connects two nodes with a loose, typed contextual association."
    },
    %{
      "kind" => "relationship",
      "type_key" => "resolves",
      "display_name" => "Resolves",
      "description" => "Connects an artifact, decision, or event to a task or risk it resolves."
    }
  ]

  def neutral_type_definitions, do: @neutral_type_definitions

  def create_type_definition(attrs) do
    %TypeDefinition{} |> TypeDefinition.changeset(attrs) |> Repo.insert()
  end

  def seed_neutral_type_definitions(workspace_id) do
    Enum.map(@neutral_type_definitions, fn attrs ->
      attrs = Map.put(attrs, "workspace_id", workspace_id)

      case Repo.get_by(TypeDefinition,
             workspace_id: workspace_id,
             kind: attrs["kind"],
             type_key: attrs["type_key"]
           ) do
        nil -> create_type_definition(attrs)
        definition -> {:ok, definition}
      end
    end)
  end

  def list_type_definitions(workspace_id, kind \\ nil) do
    TypeDefinition
    |> where([definition], definition.workspace_id == ^workspace_id)
    |> maybe_filter_kind(kind)
    |> order_by([definition], asc: definition.kind, asc: definition.type_key)
    |> Repo.all()
  end

  def create_node(attrs) do
    attrs |> change_node() |> Repo.insert()
  end

  def change_node(attrs) do
    attrs = stringify_keys(attrs)

    %Node{}
    |> Node.changeset(attrs)
    |> validate_node_provenance(attrs)
  end

  def get_node!(id), do: Repo.get!(Node, id)

  def update_node(%Node{} = node, attrs) do
    node |> Node.changeset(attrs) |> Repo.update()
  end

  def list_nodes(workspace_id, opts \\ []) do
    Node
    |> where([node], node.workspace_id == ^workspace_id)
    |> maybe_filter_type(opt(opts, :type_key))
    |> maybe_filter_status(opt(opts, :status))
    |> order_by([node], desc: node.importance, desc: node.updated_at)
    |> limit(^Keyword.get(opts, :limit, 100))
    |> Repo.all()
  end

  def search_nodes(workspace_id, query, opts \\ []) do
    like = "%#{String.replace(to_string(query || ""), "%", "\\%")}%"

    Node
    |> where([node], node.workspace_id == ^workspace_id)
    |> where([node], ilike(node.title, ^like) or ilike(node.body, ^like))
    |> order_by([node], desc: node.importance, desc: node.updated_at)
    |> limit(^Keyword.get(opts, :limit, 20))
    |> Repo.all()
  end

  def duplicate_title_groups(workspace_id) do
    Node
    |> where([node], node.workspace_id == ^workspace_id and node.status in ["active", "verified"])
    |> group_by([node], fragment("lower(?)", node.title))
    |> having([node], count(node.id) > 1)
    |> select([node], {fragment("lower(?)", node.title), count(node.id)})
    |> Repo.all()
  end

  def create_relationship(attrs) do
    attrs = stringify_keys(attrs)
    changeset = %Relationship{} |> Relationship.changeset(attrs)

    with {:ok, from_node} <- fetch_relationship_node(:from_node_id, attrs["from_node_id"]),
         {:ok, to_node} <- fetch_relationship_node(:to_node_id, attrs["to_node_id"]),
         :ok <- validate_relationship_workspace(attrs["workspace_id"], from_node, to_node) do
      changeset
      |> validate_relationship_semantics(from_node, to_node)
      |> Repo.insert()
    else
      {:error, field, message} ->
        changeset
        |> Ecto.Changeset.add_error(field, message)
        |> Repo.insert()
    end
  end

  def list_relationships(workspace_id, opts \\ []) do
    Relationship
    |> where([relationship], relationship.workspace_id == ^workspace_id)
    |> maybe_filter_type(opt(opts, :type_key))
    |> preload([:from_node, :to_node])
    |> order_by([relationship], desc: relationship.updated_at)
    |> limit(^Keyword.get(opts, :limit, 100))
    |> Repo.all()
  end

  defp maybe_filter_kind(query, nil), do: query
  defp maybe_filter_kind(query, kind), do: where(query, [definition], definition.kind == ^kind)

  defp maybe_filter_type(query, nil), do: query
  defp maybe_filter_type(query, type), do: where(query, [record], record.type_key == ^type)

  defp maybe_filter_status(query, nil), do: query
  defp maybe_filter_status(query, status), do: where(query, [node], node.status == ^status)

  defp validate_node_provenance(changeset, %{"type_key" => type_key} = attrs)
       when type_key in ["source", "artifact"] do
    provenance = attrs["provenance"] || %{}
    attributes = attrs["attributes"] || %{}

    case {type_key, provenance, attributes} do
      {"source", %{"kind" => "source_ingest"}, %{"url" => url}}
      when is_binary(url) and url != "" ->
        changeset

      {"source", _provenance, _attributes} ->
        Ecto.Changeset.add_error(
          changeset,
          :provenance,
          "source nodes require source_ingest provenance and a url"
        )

      {"artifact", %{"kind" => "artifact_record"}, attributes} ->
        if present?(attributes["path"]) or present?(attributes["uri"]) do
          changeset
        else
          Ecto.Changeset.add_error(changeset, :provenance, "artifact nodes require a path or uri")
        end

      {"artifact", _provenance, _attributes} ->
        Ecto.Changeset.add_error(
          changeset,
          :provenance,
          "artifact nodes require artifact_record provenance"
        )
    end
  end

  defp validate_node_provenance(changeset, _attrs), do: changeset

  defp fetch_relationship_node(_field, nil), do: {:error, :from_node_id, "is required"}

  defp fetch_relationship_node(field, id) do
    case Repo.get(Node, id) do
      nil -> {:error, field, "does not exist"}
      node -> {:ok, node}
    end
  end

  defp validate_relationship_workspace(workspace_id, from_node, to_node) do
    workspace_id = normalize_id(workspace_id)

    cond do
      from_node.workspace_id != workspace_id ->
        {:error, :from_node_id, "must belong to the relationship workspace"}

      to_node.workspace_id != workspace_id ->
        {:error, :to_node_id, "must belong to the relationship workspace"}

      true ->
        :ok
    end
  end

  defp validate_relationship_semantics(changeset, from_node, to_node) do
    type_key = Ecto.Changeset.get_field(changeset, :type_key)

    cond do
      type_key in ["supports", "contradicts"] and to_node.type_key != "claim" ->
        Ecto.Changeset.add_error(
          changeset,
          :to_node_id,
          "#{type_key} relationships must point to a claim"
        )

      type_key == "references" and to_node.type_key not in ["source", "artifact"] ->
        Ecto.Changeset.add_error(
          changeset,
          :to_node_id,
          "references relationships must point to a source or artifact"
        )

      type_key == "produced_by" and from_node.type_key != "artifact" ->
        Ecto.Changeset.add_error(
          changeset,
          :from_node_id,
          "produced_by relationships must start from an artifact"
        )

      type_key == "resolves" and to_node.type_key not in ["task", "risk"] ->
        Ecto.Changeset.add_error(
          changeset,
          :to_node_id,
          "resolves relationships must point to a task or risk"
        )

      true ->
        changeset
    end
  end

  defp normalize_id(id) when is_binary(id), do: String.to_integer(id)
  defp normalize_id(id), do: id

  defp present?(value), do: is_binary(value) and String.trim(value) != ""

  defp stringify_keys(map) when is_map(map),
    do: Map.new(map, fn {key, value} -> {to_string(key), value} end)

  defp opt(opts, key) when is_list(opts), do: Keyword.get(opts, key)
  defp opt(opts, key) when is_map(opts), do: Map.get(opts, key) || Map.get(opts, to_string(key))
end
