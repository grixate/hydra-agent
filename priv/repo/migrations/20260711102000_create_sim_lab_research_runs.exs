defmodule HydraAgent.Repo.Migrations.CreateSimLabResearchRuns do
  use Ecto.Migration

  def change do
    create table(:sim_lab_research_runs) do
      add :workspace_id, references(:workspaces, on_delete: :delete_all), null: false
      add :study_id, references(:sim_lab_studies, on_delete: :delete_all), null: false
      add :provider, :string, null: false
      add :status, :string, null: false, default: "queued"
      add :input_snapshot, :map, null: false, default: %{}
      add :source_count, :integer, null: false, default: 0
      add :failed_lanes, :integer, null: false, default: 0
      add :failure_reason, :text
      add :started_at, :utc_datetime_usec
      add :completed_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create index(:sim_lab_research_runs, [:workspace_id, :status])
    create index(:sim_lab_research_runs, [:study_id, :inserted_at])

    create constraint(:sim_lab_research_runs, :sim_lab_research_runs_status_check,
             check: "status IN ('queued', 'running', 'completed', 'failed', 'cancelled')"
           )

    create constraint(:sim_lab_research_runs, :sim_lab_research_runs_counts_check,
             check: "source_count >= 0 AND failed_lanes >= 0"
           )
  end
end
