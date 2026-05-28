defmodule HydraAgent.Repo.Migrations.CreateBrowserSessions do
  use Ecto.Migration

  def change do
    create table(:browser_sessions) do
      add :workspace_id, references(:workspaces, on_delete: :delete_all), null: false
      add :agent_id, references(:agent_profiles, on_delete: :nilify_all)
      add :run_id, references(:runs, on_delete: :nilify_all)
      add :status, :string, null: false, default: "active"
      add :current_url, :text
      add :worker_session_id, :string
      add :expires_at, :utc_datetime_usec
      add :last_error, :map, null: false, default: %{}
      add :metadata, :map, null: false, default: %{}

      timestamps(type: :utc_datetime_usec)
    end

    create index(:browser_sessions, [:workspace_id, :status])
    create index(:browser_sessions, [:agent_id])
    create index(:browser_sessions, [:run_id])
    create index(:browser_sessions, [:worker_session_id])

    create table(:browser_artifacts) do
      add :workspace_id, references(:workspaces, on_delete: :delete_all), null: false
      add :browser_session_id, references(:browser_sessions, on_delete: :delete_all), null: false
      add :kind, :string, null: false
      add :content_type, :string
      add :content, :text
      add :uri, :text
      add :metadata, :map, null: false, default: %{}

      timestamps(type: :utc_datetime_usec)
    end

    create index(:browser_artifacts, [:workspace_id, :kind])
    create index(:browser_artifacts, [:browser_session_id])
  end
end
