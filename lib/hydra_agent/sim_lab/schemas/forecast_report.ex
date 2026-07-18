defmodule HydraAgent.SimLab.Schemas.ForecastReport do
  use Ecto.Schema
  import Ecto.Changeset

  schema "sim_lab_forecast_reports" do
    field :title, :string
    field :executive_summary, :string
    field :outcome_probabilities, :map, default: %{}
    field :segment_reactions, {:array, :map}, default: []
    field :behavior_drivers, {:array, :map}, default: []
    field :resistance_drivers, {:array, :map}, default: []
    field :evidence_map, :map, default: %{}
    field :assumptions, {:array, :map}, default: []
    field :uncertainty, :map, default: %{}
    field :validation_recommendations, {:array, :string}, default: []
    field :markdown_body, :string
    field :export_object_key, :string

    belongs_to :run, HydraAgent.SimLab.Schemas.SimulationRun
    belongs_to :study, HydraAgent.SimLab.Schemas.Study

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(report, attrs) do
    report
    |> cast(attrs, [
      :run_id,
      :study_id,
      :title,
      :executive_summary,
      :outcome_probabilities,
      :segment_reactions,
      :behavior_drivers,
      :resistance_drivers,
      :evidence_map,
      :assumptions,
      :uncertainty,
      :validation_recommendations,
      :markdown_body,
      :export_object_key
    ])
    |> validate_required([:run_id, :study_id, :title, :executive_summary, :markdown_body])
    |> unique_constraint(:run_id)
    |> foreign_key_constraint(:run_id)
    |> foreign_key_constraint(:study_id)
  end
end
