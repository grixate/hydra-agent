defmodule HydraAgent.SimLab.Schemas.SimulationRun do
  use Ecto.Schema
  import Ecto.Changeset

  @modes ~w(tiny small medium large custom)
  @statuses ~w(queued running completed failed cancelled)

  schema "sim_lab_runs" do
    field :mode, :string
    field :agent_count, :integer
    field :rounds, :integer
    field :seed, :integer
    field :status, :string, default: "queued"
    field :budget_cap_usd, :decimal
    field :actual_cost_usd, :decimal
    field :decision_counts, :map, default: %{}
    field :aggregate_metrics, :map, default: %{}
    field :input_snapshot, :map, default: %{}
    field :input_fingerprint, :string
    field :execution_options, :map, default: %{}
    field :confidence, :float
    field :started_at, :utc_datetime_usec
    field :completed_at, :utc_datetime_usec

    belongs_to :study, HydraAgent.SimLab.Schemas.Study
    belongs_to :scenario, HydraAgent.SimLab.Schemas.Scenario
    belongs_to :context_pack, HydraAgent.SimLab.Schemas.ContextPack
    has_many :snapshots, HydraAgent.SimLab.Schemas.SimulationSnapshot, foreign_key: :run_id
    has_many :outcome_events, HydraAgent.SimLab.Schemas.OutcomeEvent, foreign_key: :run_id
    has_one :forecast_report, HydraAgent.SimLab.Schemas.ForecastReport, foreign_key: :run_id

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(run, attrs) do
    run
    |> cast(attrs, [
      :study_id,
      :scenario_id,
      :context_pack_id,
      :mode,
      :agent_count,
      :rounds,
      :seed,
      :status,
      :budget_cap_usd,
      :actual_cost_usd,
      :decision_counts,
      :aggregate_metrics,
      :input_snapshot,
      :input_fingerprint,
      :execution_options,
      :confidence,
      :started_at,
      :completed_at
    ])
    |> validate_required([
      :study_id,
      :scenario_id,
      :context_pack_id,
      :mode,
      :agent_count,
      :rounds,
      :seed,
      :status
    ])
    |> validate_inclusion(:mode, @modes)
    |> validate_inclusion(:status, @statuses)
    |> validate_number(:agent_count, greater_than: 0)
    |> validate_number(:rounds, greater_than: 0)
    |> validate_number(:budget_cap_usd, greater_than_or_equal_to: 0)
    |> validate_number(:actual_cost_usd, greater_than_or_equal_to: 0)
    |> validate_number(:confidence, greater_than_or_equal_to: 0.0, less_than_or_equal_to: 1.0)
    |> foreign_key_constraint(:study_id)
    |> foreign_key_constraint(:scenario_id)
    |> foreign_key_constraint(:context_pack_id)
  end
end
