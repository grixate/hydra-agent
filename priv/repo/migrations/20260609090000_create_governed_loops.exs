defmodule HydraAgent.Repo.Migrations.CreateGovernedLoops do
  use Ecto.Migration

  def change do
    create table(:loops) do
      add :workspace_id, references(:workspaces, on_delete: :delete_all), null: false
      add :mission_id, references(:missions, on_delete: :nilify_all)
      add :supervisor_agent_id, references(:agent_profiles, on_delete: :nilify_all)
      add :verifier_agent_id, references(:agent_profiles, on_delete: :nilify_all)
      add :name, :string, null: false
      add :slug, :string, null: false
      add :status, :string, null: false, default: "draft"
      add :purpose, :text, null: false
      add :trigger, :map, null: false, default: %{}
      add :body, :map, null: false, default: %{}
      add :autonomy_level, :string, null: false, default: "recommend"
      add :budget, :map, null: false, default: %{}
      add :guardrails, :map, null: false, default: %{}
      add :state, :map, null: false, default: %{}
      add :last_error, :map, null: false, default: %{}
      add :next_tick_at, :utc_datetime_usec
      add :last_tick_at, :utc_datetime_usec
      add :lease_owner, :string
      add :lease_expires_at, :utc_datetime_usec
      add :metadata, :map, null: false, default: %{}

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:loops, [:workspace_id, :slug])
    create index(:loops, [:workspace_id, :status])
    create index(:loops, [:next_tick_at])
    create index(:loops, [:mission_id])
    create index(:loops, [:supervisor_agent_id])
    create index(:loops, [:verifier_agent_id])
    create index(:loops, [:lease_expires_at])

    alter table(:runs) do
      add :loop_id, references(:loops, on_delete: :nilify_all)
    end

    create index(:runs, [:loop_id])
    create index(:runs, [:workspace_id, :loop_id])
  end
end
