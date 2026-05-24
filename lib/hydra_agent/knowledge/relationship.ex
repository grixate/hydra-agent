defmodule HydraAgent.Knowledge.Relationship do
  use Ecto.Schema
  import Ecto.Changeset

  schema "knowledge_relationships" do
    field :type_key, :string
    field :attributes, :map, default: %{}
    field :confidence, :float, default: 0.5
    field :provenance, :map, default: %{}

    belongs_to :workspace, HydraAgent.Runtime.Workspace
    belongs_to :from_node, HydraAgent.Knowledge.Node
    belongs_to :to_node, HydraAgent.Knowledge.Node
    belongs_to :created_by_agent, HydraAgent.Runtime.AgentProfile

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(relationship, attrs) do
    relationship
    |> cast(attrs, [
      :workspace_id,
      :from_node_id,
      :to_node_id,
      :created_by_agent_id,
      :type_key,
      :attributes,
      :confidence,
      :provenance
    ])
    |> validate_required([:workspace_id, :from_node_id, :to_node_id, :type_key])
    |> validate_format(:type_key, ~r/^[a-z][a-z0-9_]*$/)
    |> validate_number(:confidence, greater_than_or_equal_to: 0.0, less_than_or_equal_to: 1.0)
    |> assoc_constraint(:workspace)
    |> assoc_constraint(:from_node)
    |> assoc_constraint(:to_node)
    |> assoc_constraint(:created_by_agent)
  end
end
