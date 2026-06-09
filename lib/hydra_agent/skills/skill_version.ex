defmodule HydraAgent.Skills.SkillVersion do
  use Ecto.Schema
  import Ecto.Changeset

  @change_kinds ~w(created testing active deprecated archived updated restored)

  schema "skill_versions" do
    field :version, :integer
    field :change_kind, :string
    field :status, :string
    field :snapshot, :map, default: %{}
    field :metadata, :map, default: %{}

    belongs_to :workspace, HydraAgent.Runtime.Workspace
    belongs_to :skill, HydraAgent.Skills.Skill

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(skill_version, attrs) do
    skill_version
    |> cast(attrs, [
      :workspace_id,
      :skill_id,
      :version,
      :change_kind,
      :status,
      :snapshot,
      :metadata
    ])
    |> validate_required([:workspace_id, :skill_id, :version, :change_kind, :status])
    |> validate_number(:version, greater_than: 0)
    |> validate_inclusion(:change_kind, @change_kinds)
    |> assoc_constraint(:workspace)
    |> assoc_constraint(:skill)
    |> unique_constraint([:skill_id, :version])
  end
end
