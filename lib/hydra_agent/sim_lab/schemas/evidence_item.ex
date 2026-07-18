defmodule HydraAgent.SimLab.Schemas.EvidenceItem do
  use Ecto.Schema
  import Ecto.Changeset

  @grounding ~w(direct_user_data external_research analogue_evidence domain_prior assumption contradicted)

  schema "sim_lab_evidence_items" do
    field :kind, :string, default: "claim"
    field :claim, :string
    field :normalized_claim, :string
    field :source_ref, :map, default: %{}
    field :grounding_level, :string
    field :reliability_score, :float
    field :relevance_score, :float
    field :freshness_score, :float
    field :confidence_score, :float
    field :simulation_impact, :string
    field :tags, {:array, :string}, default: []
    field :metadata, :map, default: %{}

    belongs_to :study, HydraAgent.SimLab.Schemas.Study
    belongs_to :source, HydraAgent.SimLab.Schemas.Source

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(item, attrs) do
    item
    |> cast(attrs, [
      :study_id,
      :source_id,
      :kind,
      :claim,
      :normalized_claim,
      :source_ref,
      :grounding_level,
      :reliability_score,
      :relevance_score,
      :freshness_score,
      :confidence_score,
      :simulation_impact,
      :tags,
      :metadata
    ])
    |> validate_required([
      :study_id,
      :kind,
      :claim,
      :normalized_claim,
      :grounding_level,
      :simulation_impact
    ])
    |> validate_inclusion(:grounding_level, @grounding)
    |> validate_score(:reliability_score)
    |> validate_score(:relevance_score)
    |> validate_score(:freshness_score)
    |> validate_score(:confidence_score)
    |> foreign_key_constraint(:study_id)
    |> foreign_key_constraint(:source_id)
  end

  defp validate_score(changeset, field),
    do:
      validate_number(changeset, field, greater_than_or_equal_to: 0.0, less_than_or_equal_to: 1.0)
end
