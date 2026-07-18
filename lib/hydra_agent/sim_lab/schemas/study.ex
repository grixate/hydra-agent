defmodule HydraAgent.SimLab.Schemas.Study do
  use Ecto.Schema
  import Ecto.Changeset

  @statuses ~w(draft context_ready personas_ready patterns_ready simulation_ready completed)

  schema "sim_lab_studies" do
    field :title, :string
    field :question, :string
    field :domain, :string
    field :region, :string
    field :language, :string
    field :timeframe, :string
    field :target_audience, :string
    field :desired_outcomes, :map, default: %{}
    field :status, :string, default: "draft"

    belongs_to :workspace, HydraAgent.Runtime.Workspace
    has_many :sources, HydraAgent.SimLab.Schemas.Source
    has_many :evidence_items, HydraAgent.SimLab.Schemas.EvidenceItem
    has_many :context_packs, HydraAgent.SimLab.Schemas.ContextPack
    has_many :personas, HydraAgent.SimLab.Schemas.Persona
    has_many :action_patterns, HydraAgent.SimLab.Schemas.ActionPattern
    has_many :scenarios, HydraAgent.SimLab.Schemas.Scenario
    has_many :runs, HydraAgent.SimLab.Schemas.SimulationRun
    has_many :forecast_reports, HydraAgent.SimLab.Schemas.ForecastReport
    has_many :research_runs, HydraAgent.SimLab.Schemas.ResearchRun

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(study, attrs) do
    study
    |> cast(attrs, [
      :workspace_id,
      :title,
      :question,
      :domain,
      :region,
      :language,
      :timeframe,
      :target_audience,
      :desired_outcomes,
      :status
    ])
    |> validate_required([:workspace_id, :title, :question, :status])
    |> validate_length(:title, max: 180)
    |> validate_inclusion(:status, @statuses)
    |> foreign_key_constraint(:workspace_id)
  end
end
