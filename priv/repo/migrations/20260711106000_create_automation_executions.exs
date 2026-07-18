defmodule HydraAgent.Repo.Migrations.CreateAutomationExecutions do
  use Ecto.Migration

  def change do
    create table(:automation_executions) do
      add :workspace_id, references(:workspaces, on_delete: :delete_all), null: false
      add :automation_id, references(:automations, on_delete: :delete_all), null: false
      add :run_id, references(:runs, on_delete: :nilify_all)
      add :trigger, :string, null: false
      add :status, :string, null: false, default: "claimed"
      add :scheduled_for, :utc_datetime_usec, null: false
      add :next_scheduled_for, :utc_datetime_usec, null: false
      add :claimed_at, :utc_datetime_usec, null: false
      add :started_at, :utc_datetime_usec
      add :finished_at, :utc_datetime_usec
      add :result, :map, null: false, default: %{}
      add :last_error, :map, null: false, default: %{}
      add :metadata, :map, null: false, default: %{}

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:automation_executions, [:automation_id, :scheduled_for],
             name: :automation_executions_occurrence_index
           )

    create index(:automation_executions, [:workspace_id, :status, :scheduled_for])
    create index(:automation_executions, [:automation_id, :status])
    create index(:automation_executions, [:run_id])

    create constraint(:automation_executions, :automation_executions_trigger_check,
             check: "trigger IN ('scheduled', 'manual')"
           )

    create constraint(:automation_executions, :automation_executions_status_check,
             check: "status IN ('claimed', 'running', 'completed', 'failed', 'blocked')"
           )
  end
end
