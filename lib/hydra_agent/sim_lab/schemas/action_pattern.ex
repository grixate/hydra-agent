defmodule HydraAgent.SimLab.Schemas.ActionPattern do
  use Ecto.Schema
  import Ecto.Changeset

  @statuses ~w(active archived)
  @grounding ~w(direct_user_data external_research analogue_evidence domain_prior assumption contradicted)
  @actions ~w(adopt resist ignore share)

  schema "sim_lab_action_patterns" do
    field :name, :string
    field :persona_ids, {:array, :integer}, default: []
    field :condition, :string
    field :interpretation, :string
    field :motivation, :string
    field :likely_action, :string
    field :base_probability, :float
    field :blockers, {:array, :map}, default: []
    field :amplifiers, {:array, :map}, default: []
    field :state_updates, :map, default: %{}
    field :grounding_level, :string
    field :evidence_refs, {:array, :string}, default: []
    field :assumption_refs, {:array, :string}, default: []
    field :confidence, :float
    field :executable_rule, :map, default: %{}
    field :version, :integer, default: 1
    field :status, :string, default: "active"

    belongs_to :study, HydraAgent.SimLab.Schemas.Study

    many_to_many :personas, HydraAgent.SimLab.Schemas.Persona,
      join_through: "sim_lab_action_pattern_personas",
      join_keys: [action_pattern_id: :id, persona_id: :id]

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(pattern, attrs) do
    pattern
    |> cast(attrs, [
      :study_id,
      :name,
      :persona_ids,
      :condition,
      :interpretation,
      :motivation,
      :likely_action,
      :base_probability,
      :blockers,
      :amplifiers,
      :state_updates,
      :grounding_level,
      :evidence_refs,
      :assumption_refs,
      :confidence,
      :executable_rule,
      :version,
      :status
    ])
    |> validate_required([
      :study_id,
      :name,
      :condition,
      :interpretation,
      :motivation,
      :likely_action,
      :base_probability,
      :grounding_level,
      :status
    ])
    |> validate_number(:base_probability,
      greater_than_or_equal_to: 0.0,
      less_than_or_equal_to: 1.0
    )
    |> validate_number(:confidence, greater_than_or_equal_to: 0.0, less_than_or_equal_to: 1.0)
    |> validate_number(:version, greater_than: 0)
    |> validate_inclusion(:likely_action, @actions)
    |> validate_inclusion(:grounding_level, @grounding)
    |> validate_inclusion(:status, @statuses)
    |> foreign_key_constraint(:study_id)
  end
end
