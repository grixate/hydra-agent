defmodule HydraAgent.Simulations.Blueprint do
  @moduledoc "A reusable, workspace-scoped simulation construction method."

  use Ecto.Schema
  import Ecto.Changeset

  alias HydraAgent.Simulations.BlueprintVersion

  @statuses ~w(active archived)

  schema "simulation_blueprints" do
    field :slug, :string
    field :name, :map, default: %{}
    field :description, :map, default: %{}
    field :status, :string, default: "active"
    field :built_in, :boolean, default: false
    field :origin, :map, default: %{}

    belongs_to :workspace, HydraAgent.Runtime.Workspace
    belongs_to :owner_user, HydraAgent.Accounts.User
    belongs_to :source_blueprint, __MODULE__
    belongs_to :active_version, BlueprintVersion
    has_many :versions, BlueprintVersion
    has_many :simulations, HydraAgent.Simulations.Simulation, foreign_key: :selected_blueprint_id

    timestamps(type: :utc_datetime_usec)
  end

  def statuses, do: @statuses

  def create_changeset(blueprint, attrs) do
    blueprint
    |> cast(attrs, [
      :workspace_id,
      :owner_user_id,
      :source_blueprint_id,
      :slug,
      :name,
      :description,
      :status,
      :built_in,
      :origin
    ])
    |> validate_required([:slug, :name, :description, :status, :built_in])
    |> validate_format(:slug, ~r/^[a-z0-9][a-z0-9-]*$/)
    |> validate_length(:slug, min: 2, max: 100)
    |> validate_inclusion(:status, @statuses)
    |> validate_localized(:name, 2, 100)
    |> validate_localized(:description, 8, 500)
    |> validate_scope()
    |> check_constraint(:slug, name: :simulation_blueprints_builtin_slug_check)
    |> assoc_constraint(:workspace)
    |> assoc_constraint(:owner_user)
    |> assoc_constraint(:source_blueprint)
    |> unique_constraint(:slug, name: :simulation_blueprints_system_slug_index)
    |> unique_constraint([:workspace_id, :slug],
      name: :simulation_blueprints_workspace_slug_index
    )
  end

  def activate_version_changeset(blueprint, version_id, manifest) do
    blueprint
    |> change(%{
      active_version_id: version_id,
      name: manifest["name"],
      description: manifest["description"]
    })
    |> foreign_key_constraint(:active_version_id)
  end

  def archive_changeset(blueprint) do
    blueprint
    |> change(status: "archived")
    |> check_constraint(:status, name: :simulation_blueprints_status_check)
  end

  defp validate_localized(changeset, field, min, max) do
    validate_change(changeset, field, fn ^field, value ->
      errors =
        for locale <- ["en", "ru"],
            text = value[locale],
            not (is_binary(text) and String.length(String.trim(text)) in min..max),
            do: "must include #{locale} text between #{min} and #{max} characters"

      Enum.map(errors, &{field, &1})
    end)
  end

  defp validate_scope(changeset) do
    built_in = get_field(changeset, :built_in)
    workspace_id = get_field(changeset, :workspace_id)
    owner_user_id = get_field(changeset, :owner_user_id)

    cond do
      built_in and (workspace_id || owner_user_id) ->
        add_error(changeset, :built_in, "system Blueprints cannot belong to a workspace or user")

      not built_in and is_nil(workspace_id) ->
        add_error(changeset, :workspace_id, "is required for a custom Blueprint")

      true ->
        changeset
    end
  end
end
