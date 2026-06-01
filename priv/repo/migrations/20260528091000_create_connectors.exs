defmodule HydraAgent.Repo.Migrations.CreateConnectors do
  use Ecto.Migration

  def change do
    create table(:connector_accounts) do
      add :workspace_id, references(:workspaces, on_delete: :delete_all), null: false
      add :provider, :string, null: false
      add :slug, :string, null: false
      add :display_name, :string, null: false
      add :status, :string, null: false, default: "active"
      add :credential_env, :string
      add :refresh_env, :string
      add :config, :map, null: false, default: %{}
      add :capabilities, {:array, :string}, null: false, default: []
      add :last_health, :map, null: false, default: %{}
      add :last_error, :map, null: false, default: %{}
      add :metadata, :map, null: false, default: %{}

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:connector_accounts, [:workspace_id, :slug])
    create index(:connector_accounts, [:workspace_id, :provider])
    create index(:connector_accounts, [:workspace_id, :status])

    create table(:connector_actions) do
      add :workspace_id, references(:workspaces, on_delete: :delete_all), null: false

      add :connector_account_id, references(:connector_accounts, on_delete: :delete_all),
        null: false

      add :agent_id, references(:agent_profiles, on_delete: :nilify_all)
      add :automation_id, references(:automations, on_delete: :nilify_all)
      add :provider, :string, null: false
      add :action, :string, null: false
      add :side_effect_class, :string, null: false
      add :status, :string, null: false, default: "queued"
      add :input, :map, null: false, default: %{}
      add :result, :map, null: false, default: %{}
      add :last_error, :map, null: false, default: %{}
      add :requested_by, :string, null: false, default: "agent"
      add :approved_by, :string
      add :approved_at, :utc_datetime_usec
      add :executed_at, :utc_datetime_usec
      add :metadata, :map, null: false, default: %{}

      timestamps(type: :utc_datetime_usec)
    end

    create index(:connector_actions, [:workspace_id, :status])
    create index(:connector_actions, [:workspace_id, :provider, :action])
    create index(:connector_actions, [:connector_account_id, :status])
    create index(:connector_actions, [:agent_id])
    create index(:connector_actions, [:automation_id])
  end
end
