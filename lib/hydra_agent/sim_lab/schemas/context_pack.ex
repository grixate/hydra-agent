defmodule HydraAgent.SimLab.Schemas.ContextPack do
  use Ecto.Schema
  import Ecto.Changeset

  @statuses ~w(draft active superseded)

  schema "sim_lab_context_packs" do
    field :version, :integer, default: 1
    field :summary, :map, default: %{}
    field :source_mix, :map, default: %{}
    field :key_findings, {:array, :map}, default: []
    field :market_context, {:array, :map}, default: []
    field :behavioral_context, {:array, :map}, default: []
    field :recent_context, {:array, :map}, default: []
    field :regulatory_context, {:array, :map}, default: []
    field :risks, {:array, :map}, default: []
    field :assumptions, {:array, :map}, default: []
    field :open_questions, {:array, :map}, default: []
    field :simulation_implications, {:array, :map}, default: []
    field :confidence, :float
    field :generated_by_protocol_version, :string
    field :status, :string, default: "draft"

    belongs_to :study, HydraAgent.SimLab.Schemas.Study

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(pack, attrs) do
    pack
    |> cast(attrs, [
      :study_id,
      :version,
      :summary,
      :source_mix,
      :key_findings,
      :market_context,
      :behavioral_context,
      :recent_context,
      :regulatory_context,
      :risks,
      :assumptions,
      :open_questions,
      :simulation_implications,
      :confidence,
      :generated_by_protocol_version,
      :status
    ])
    |> validate_required([:study_id, :version, :status])
    |> validate_number(:version, greater_than: 0)
    |> validate_number(:confidence, greater_than_or_equal_to: 0.0, less_than_or_equal_to: 1.0)
    |> validate_inclusion(:status, @statuses)
    |> unique_constraint([:study_id, :version])
    |> foreign_key_constraint(:study_id)
  end
end
