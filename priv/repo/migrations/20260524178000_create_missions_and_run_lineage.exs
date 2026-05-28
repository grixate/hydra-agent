defmodule HydraAgent.Repo.Migrations.CreateMissionsAndRunLineage do
  use Ecto.Migration

  def up do
    create table(:missions) do
      add :workspace_id, references(:workspaces, on_delete: :delete_all), null: false
      add :supervisor_agent_id, references(:agent_profiles, on_delete: :nilify_all)
      add :title, :string, null: false
      add :slug, :string, null: false
      add :objective, :text, null: false
      add :mission_type, :string, null: false, default: "custom"
      add :status, :string, null: false, default: "draft"
      add :priority, :integer, null: false, default: 0
      add :deadline_at, :utc_datetime_usec
      add :success_criteria, :map, null: false, default: %{}
      add :context, :map, null: false, default: %{}
      add :team, :map, null: false, default: %{}
      add :permissions, :map, null: false, default: %{}
      add :budget, :map, null: false, default: %{}
      add :start_mode, :string, null: false, default: "draft"
      add :metadata, :map, null: false, default: %{}
      add :started_at, :utc_datetime_usec
      add :completed_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:missions, [:workspace_id, :slug])
    create index(:missions, [:workspace_id, :status])
    create index(:missions, [:workspace_id, :priority])

    alter table(:runs) do
      add :mission_id, references(:missions, on_delete: :nilify_all)
      add :parent_run_id, references(:runs, on_delete: :nilify_all)
      add :lineage_type, :string, null: false, default: "original"
      add :lineage_reason, :text
    end

    create index(:runs, [:mission_id])
    create index(:runs, [:parent_run_id])
    create index(:runs, [:workspace_id, :mission_id])

    execute """
    INSERT INTO missions (
      workspace_id,
      supervisor_agent_id,
      title,
      slug,
      objective,
      mission_type,
      status,
      priority,
      budget,
      metadata,
      started_at,
      completed_at,
      inserted_at,
      updated_at
    )
    SELECT
      workspace_id,
      supervisor_agent_id,
      title,
      'legacy-run-' || id::text,
      goal,
      'custom',
      CASE
        WHEN status IN ('planned', 'running', 'paused', 'blocked', 'awaiting_approval', 'completed', 'failed', 'canceled')
        THEN status
        ELSE 'planned'
      END,
      priority,
      budget,
      jsonb_build_object('created_from', 'legacy_run_backfill', 'legacy_run_id', id),
      started_at,
      completed_at,
      inserted_at,
      updated_at
    FROM runs
    WHERE mission_id IS NULL
    """

    execute """
    UPDATE runs
    SET mission_id = missions.id
    FROM missions
    WHERE missions.metadata->>'legacy_run_id' = runs.id::text
      AND runs.mission_id IS NULL
    """
  end

  def down do
    drop_if_exists index(:runs, [:workspace_id, :mission_id])
    drop_if_exists index(:runs, [:parent_run_id])
    drop_if_exists index(:runs, [:mission_id])

    alter table(:runs) do
      remove :lineage_reason
      remove :lineage_type
      remove :parent_run_id
      remove :mission_id
    end

    drop_if_exists index(:missions, [:workspace_id, :priority])
    drop_if_exists index(:missions, [:workspace_id, :status])
    drop_if_exists unique_index(:missions, [:workspace_id, :slug])
    drop table(:missions)
  end
end
