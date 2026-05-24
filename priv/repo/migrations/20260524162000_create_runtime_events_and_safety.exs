defmodule HydraAgent.Repo.Migrations.CreateRuntimeEventsAndSafety do
  use Ecto.Migration

  def change do
    create table(:run_events) do
      add :workspace_id, references(:workspaces, on_delete: :delete_all), null: false
      add :run_id, references(:runs, on_delete: :delete_all), null: false
      add :run_step_id, references(:run_steps, on_delete: :nilify_all)
      add :agent_id, references(:agent_profiles, on_delete: :nilify_all)
      add :event_type, :string, null: false
      add :summary, :text, null: false
      add :payload, :map, null: false, default: %{}

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create index(:run_events, [:run_id, :inserted_at])
    create index(:run_events, [:workspace_id, :event_type])

    create table(:safety_events) do
      add :workspace_id, references(:workspaces, on_delete: :delete_all), null: false
      add :agent_id, references(:agent_profiles, on_delete: :nilify_all)
      add :run_id, references(:runs, on_delete: :nilify_all)
      add :run_step_id, references(:run_steps, on_delete: :nilify_all)
      add :category, :string, null: false
      add :severity, :string, null: false, default: "info"
      add :action, :string, null: false
      add :summary, :text, null: false
      add :metadata, :map, null: false, default: %{}
      add :acknowledged_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create index(:safety_events, [:workspace_id, :category])
    create index(:safety_events, [:run_id])
    create index(:safety_events, [:agent_id])
  end
end
