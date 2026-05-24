defmodule HydraAgent.Knowledge.TypeDefinition do
  use Ecto.Schema
  import Ecto.Changeset

  @kinds ~w(node relationship)

  schema "knowledge_type_definitions" do
    field :kind, :string
    field :type_key, :string
    field :display_name, :string
    field :description, :string
    field :extends, :string
    field :attribute_schema, :map, default: %{}
    field :status_vocabulary, {:array, :string}, default: []
    field :metadata, :map, default: %{}

    belongs_to :workspace, HydraAgent.Runtime.Workspace

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(definition, attrs) do
    definition
    |> cast(attrs, [
      :workspace_id,
      :kind,
      :type_key,
      :display_name,
      :description,
      :extends,
      :attribute_schema,
      :status_vocabulary,
      :metadata
    ])
    |> validate_required([:workspace_id, :kind, :type_key, :display_name])
    |> validate_inclusion(:kind, @kinds)
    |> validate_format(:type_key, ~r/^[a-z][a-z0-9_]*$/)
    |> assoc_constraint(:workspace)
    |> unique_constraint([:workspace_id, :kind, :type_key])
  end
end
