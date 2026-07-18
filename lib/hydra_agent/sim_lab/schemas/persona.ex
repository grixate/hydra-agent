defmodule HydraAgent.SimLab.Schemas.Persona do
  use Ecto.Schema
  import Ecto.Changeset

  @statuses ~w(active archived)

  schema "sim_lab_personas" do
    field :name, :string
    field :segment, :string
    field :distribution_weight, :float
    field :goals, {:array, :string}, default: []
    field :frictions, {:array, :string}, default: []
    field :triggers, {:array, :string}, default: []
    field :trust_factors, {:array, :string}, default: []
    field :decision_style, :string
    field :likely_actions, {:array, :string}, default: []
    field :behavioral_parameters, :map, default: %{}
    field :evidence_refs, {:array, :string}, default: []
    field :assumption_refs, {:array, :string}, default: []
    field :grounding_mix, :map, default: %{}
    field :confidence, :float
    field :editable_notes, :string
    field :version, :integer, default: 1
    field :status, :string, default: "active"

    belongs_to :study, HydraAgent.SimLab.Schemas.Study

    many_to_many :action_patterns, HydraAgent.SimLab.Schemas.ActionPattern,
      join_through: "sim_lab_action_pattern_personas",
      join_keys: [persona_id: :id, action_pattern_id: :id]

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(persona, attrs) do
    persona
    |> cast(attrs, [
      :study_id,
      :name,
      :segment,
      :distribution_weight,
      :goals,
      :frictions,
      :triggers,
      :trust_factors,
      :decision_style,
      :likely_actions,
      :behavioral_parameters,
      :evidence_refs,
      :assumption_refs,
      :grounding_mix,
      :confidence,
      :editable_notes,
      :version,
      :status
    ])
    |> validate_required([:study_id, :name, :segment, :distribution_weight, :status])
    |> validate_number(:distribution_weight, greater_than: 0.0, less_than_or_equal_to: 1.0)
    |> validate_number(:confidence, greater_than_or_equal_to: 0.0, less_than_or_equal_to: 1.0)
    |> validate_number(:version, greater_than: 0)
    |> validate_inclusion(:status, @statuses)
    |> foreign_key_constraint(:study_id)
  end
end
