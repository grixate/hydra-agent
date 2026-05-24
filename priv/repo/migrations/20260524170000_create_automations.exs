defmodule HydraAgent.Repo.Migrations.CreateAutomations do
  use Ecto.Migration

  def change do
    create table(:automations) do
      add :workspace_id, references(:workspaces, on_delete: :delete_all), null: false
      add :agent_id, references(:agent_profiles, on_delete: :delete_all), null: false
      add :name, :string, null: false
      add :slug, :string, null: false
      add :status, :string, null: false, default: "active"
      add :cron_expression, :string, null: false
      add :timezone, :string, null: false, default: "Etc/UTC"
      add :prompt, :text, null: false
      add :last_run_at, :utc_datetime_usec
      add :next_run_at, :utc_datetime_usec
      add :last_error, :map, null: false, default: %{}
      add :metadata, :map, null: false, default: %{}

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:automations, [:workspace_id, :slug])
    create index(:automations, [:workspace_id, :status])
    create index(:automations, [:next_run_at])
    create index(:automations, [:agent_id])
  end
end
