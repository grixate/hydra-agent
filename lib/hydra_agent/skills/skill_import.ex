defmodule HydraAgent.Skills.SkillImport do
  use Ecto.Schema
  import Ecto.Changeset

  @source_types ~w(local_path github raw)
  @statuses ~w(scanned blocked approved installed rejected)

  schema "skill_imports" do
    field :source_type, :string
    field :source_url, :string
    field :source_path, :string
    field :source_ref, :string
    field :status, :string, default: "scanned"
    field :skill_attrs, :map, default: %{}
    field :file_manifest, {:array, :map}, default: []
    field :scan_result, :map, default: %{}
    field :warnings, {:array, :map}, default: []
    field :approved_by, :string
    field :approved_at, :utc_datetime_usec
    field :metadata, :map, default: %{}

    belongs_to :workspace, HydraAgent.Runtime.Workspace
    belongs_to :installed_skill, HydraAgent.Skills.Skill

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(skill_import, attrs) do
    skill_import
    |> cast(attrs, [
      :workspace_id,
      :installed_skill_id,
      :source_type,
      :source_url,
      :source_path,
      :source_ref,
      :status,
      :skill_attrs,
      :file_manifest,
      :scan_result,
      :warnings,
      :approved_by,
      :approved_at,
      :metadata
    ])
    |> validate_required([:workspace_id, :source_type, :status, :skill_attrs])
    |> validate_inclusion(:source_type, @source_types)
    |> validate_inclusion(:status, @statuses)
    |> assoc_constraint(:workspace)
    |> assoc_constraint(:installed_skill)
  end
end
