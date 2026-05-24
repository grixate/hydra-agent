defmodule HydraAgent.Knowledge.Node do
  use Ecto.Schema
  import Ecto.Changeset

  @statuses ~w(draft active verified conflicted superseded archived)

  schema "knowledge_nodes" do
    field :type_key, :string
    field :title, :string
    field :body, :string
    field :status, :string, default: "active"
    field :attributes, :map, default: %{}
    field :importance, :float, default: 0.5
    field :confidence, :float, default: 0.5
    field :provenance, :map, default: %{}
    field :created_by_operator, :boolean, default: false

    belongs_to :workspace, HydraAgent.Runtime.Workspace
    belongs_to :created_by_agent, HydraAgent.Runtime.AgentProfile

    has_many :outgoing_relationships,
             HydraAgent.Knowledge.Relationship,
             foreign_key: :from_node_id

    has_many :incoming_relationships,
             HydraAgent.Knowledge.Relationship,
             foreign_key: :to_node_id

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(node, attrs) do
    node
    |> cast(attrs, [
      :workspace_id,
      :created_by_agent_id,
      :type_key,
      :title,
      :body,
      :status,
      :attributes,
      :importance,
      :confidence,
      :provenance,
      :created_by_operator
    ])
    |> validate_required([:workspace_id, :type_key, :title, :status])
    |> validate_format(:type_key, ~r/^[a-z][a-z0-9_]*$/)
    |> validate_inclusion(:status, @statuses)
    |> validate_number(:importance, greater_than_or_equal_to: 0.0, less_than_or_equal_to: 1.0)
    |> validate_number(:confidence, greater_than_or_equal_to: 0.0, less_than_or_equal_to: 1.0)
    |> assoc_constraint(:workspace)
    |> assoc_constraint(:created_by_agent)
  end
end
