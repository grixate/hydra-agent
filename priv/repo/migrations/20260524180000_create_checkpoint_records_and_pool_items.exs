defmodule HydraAgent.Repo.Migrations.CreateCheckpointRecordsAndPoolItems do
  use Ecto.Migration

  def change do
    create table(:tool_checkpoints) do
      add :workspace_id, references(:workspaces, on_delete: :delete_all)
      add :run_id, references(:runs, on_delete: :nilify_all)
      add :run_step_id, references(:run_steps, on_delete: :nilify_all)
      add :tool_name, :string
      add :path, :text, null: false
      add :relative_path, :text
      add :checkpoint_path, :text
      add :sha256, :string
      add :existed, :boolean, null: false, default: false
      add :restored_at, :utc_datetime_usec
      add :metadata, :map, null: false, default: %{}

      timestamps(type: :utc_datetime_usec)
    end

    create index(:tool_checkpoints, [:workspace_id, :inserted_at])
    create index(:tool_checkpoints, [:run_id])
    create index(:tool_checkpoints, [:run_step_id])

    create table(:credential_pool_items) do
      add :credential_pool_id, references(:credential_pools, on_delete: :delete_all), null: false
      add :label, :string, null: false
      add :source, :string, null: false, default: "env"
      add :env_var, :string, null: false
      add :status, :string, null: false, default: "active"
      add :priority, :integer, null: false, default: 0
      add :request_count, :integer, null: false, default: 0
      add :failure_count, :integer, null: false, default: 0
      add :cooldown_until, :utc_datetime_usec
      add :last_used_at, :utc_datetime_usec
      add :last_error, :map, null: false, default: %{}
      add :metadata, :map, null: false, default: %{}

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:credential_pool_items, [:credential_pool_id, :env_var])
    create index(:credential_pool_items, [:credential_pool_id, :status, :priority])
    create index(:credential_pool_items, [:credential_pool_id, :cooldown_until])
  end
end
