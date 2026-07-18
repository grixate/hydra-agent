defmodule HydraAgent.SimLab.Schemas.ResearchRun do
  use Ecto.Schema
  import Ecto.Changeset

  @providers ~w(web_search codex_cli_test mock)
  @statuses ~w(queued running completed failed cancelled)

  schema "sim_lab_research_runs" do
    field :provider, :string
    field :status, :string, default: "queued"
    field :input_snapshot, :map, default: %{}
    field :source_count, :integer, default: 0
    field :failed_lanes, :integer, default: 0
    field :failure_reason, :string
    field :started_at, :utc_datetime_usec
    field :completed_at, :utc_datetime_usec

    belongs_to :workspace, HydraAgent.Runtime.Workspace
    belongs_to :study, HydraAgent.SimLab.Schemas.Study

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(run, attrs) do
    run
    |> cast(attrs, [
      :workspace_id,
      :study_id,
      :provider,
      :status,
      :input_snapshot,
      :source_count,
      :failed_lanes,
      :failure_reason,
      :started_at,
      :completed_at
    ])
    |> validate_required([:workspace_id, :study_id, :provider, :status])
    |> validate_inclusion(:provider, @providers)
    |> validate_inclusion(:status, @statuses)
    |> validate_number(:source_count, greater_than_or_equal_to: 0)
    |> validate_number(:failed_lanes, greater_than_or_equal_to: 0)
    |> foreign_key_constraint(:workspace_id)
    |> foreign_key_constraint(:study_id)
  end
end
