defmodule HydraAgent.Repo.Migrations.CreateUsageRecords do
  use Ecto.Migration

  def change do
    create table(:usage_records) do
      add :workspace_id, references(:workspaces, on_delete: :delete_all), null: false
      add :agent_id, references(:agent_profiles, on_delete: :nilify_all)
      add :run_id, references(:runs, on_delete: :nilify_all)
      add :run_step_id, references(:run_steps, on_delete: :nilify_all)
      add :conversation_id, references(:conversations, on_delete: :nilify_all)
      add :turn_id, references(:turns, on_delete: :nilify_all)
      add :provider, :string
      add :model, :string
      add :category, :string, null: false
      add :status, :string, null: false, default: "ok"
      add :input_tokens, :integer, null: false, default: 0
      add :output_tokens, :integer, null: false, default: 0
      add :total_tokens, :integer, null: false, default: 0
      add :estimated_cost, :decimal
      add :latency_ms, :integer
      add :metadata, :map, null: false, default: %{}

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create index(:usage_records, [:workspace_id, :inserted_at])
    create index(:usage_records, [:agent_id])
    create index(:usage_records, [:run_id])
    create index(:usage_records, [:conversation_id])
    create index(:usage_records, [:category])
  end
end
