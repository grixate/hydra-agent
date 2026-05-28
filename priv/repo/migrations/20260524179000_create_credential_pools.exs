defmodule HydraAgent.Repo.Migrations.CreateCredentialPools do
  use Ecto.Migration

  def change do
    create table(:credential_pools) do
      add :workspace_id, references(:workspaces, on_delete: :delete_all)
      add :name, :string, null: false
      add :slug, :string, null: false
      add :kind, :string, null: false, default: "provider"
      add :status, :string, null: false, default: "active"
      add :env_vars, {:array, :string}, null: false, default: []
      add :metadata, :map, null: false, default: %{}

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:credential_pools, [:workspace_id, :slug])
    create index(:credential_pools, [:workspace_id, :status])

    alter table(:provider_configs) do
      add :credential_pool_id, references(:credential_pools, on_delete: :nilify_all)
    end

    create index(:provider_configs, [:credential_pool_id])
  end
end
