defmodule HydraAgent.Repo.Migrations.CreateWebhookEndpoints do
  use Ecto.Migration

  def change do
    create table(:webhook_endpoints) do
      add :workspace_id, references(:workspaces, on_delete: :delete_all), null: false
      add :agent_id, references(:agent_profiles, on_delete: :nilify_all)
      add :name, :string, null: false
      add :slug, :string, null: false
      add :status, :string, null: false, default: "active"
      add :target_type, :string, null: false
      add :token_env, :string, null: false
      add :config, :map, null: false, default: %{}
      add :last_received_at, :utc_datetime_usec
      add :last_error, :map, null: false, default: %{}
      add :metadata, :map, null: false, default: %{}

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:webhook_endpoints, [:workspace_id, :slug])
    create index(:webhook_endpoints, [:slug])
    create index(:webhook_endpoints, [:workspace_id, :status])
  end
end
