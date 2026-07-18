defmodule HydraAgent.Simulations.BlueprintVersion do
  @moduledoc "An immutable, content-addressed Blueprint package snapshot."

  use Ecto.Schema
  import Ecto.Changeset

  @validation_statuses ~w(valid invalid)

  schema "simulation_blueprint_versions" do
    field :version, :string
    field :manifest, :map, default: %{}
    field :instructions, :map, default: %{}
    field :schemas, :map, default: %{}
    field :examples, :map, default: %{}
    field :readme, :string, default: ""
    field :capability_requirements, :map, default: %{}
    field :content_hash, :string
    field :validation_status, :string, default: "valid"
    field :validation_errors, {:array, :map}, default: []
    field :compatibility_warnings, {:array, :string}, default: []

    belongs_to :workspace, HydraAgent.Runtime.Workspace
    belongs_to :blueprint, HydraAgent.Simulations.Blueprint
    belongs_to :created_by_user, HydraAgent.Accounts.User

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  def create_changeset(version, attrs) do
    version
    |> cast(attrs, [
      :workspace_id,
      :blueprint_id,
      :created_by_user_id,
      :version,
      :manifest,
      :instructions,
      :schemas,
      :examples,
      :readme,
      :capability_requirements,
      :content_hash,
      :validation_status,
      :validation_errors,
      :compatibility_warnings
    ])
    |> validate_required([
      :blueprint_id,
      :version,
      :manifest,
      :instructions,
      :schemas,
      :content_hash,
      :validation_status
    ])
    |> validate_change(:version, fn :version, value ->
      if Version.parse(value) == :error, do: [version: "must be semantic versioning"], else: []
    end)
    |> validate_format(:content_hash, ~r/^[a-f0-9]{64}$/)
    |> validate_inclusion(:validation_status, @validation_statuses)
    |> assoc_constraint(:workspace)
    |> assoc_constraint(:blueprint)
    |> assoc_constraint(:created_by_user)
    |> unique_constraint([:blueprint_id, :version])
    |> unique_constraint([:blueprint_id, :content_hash])
  end
end
