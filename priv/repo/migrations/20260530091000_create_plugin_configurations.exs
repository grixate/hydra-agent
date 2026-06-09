defmodule HydraAgent.Repo.Migrations.CreatePluginConfigurations do
  use Ecto.Migration

  def change do
    create table(:plugin_configurations) do
      add :workspace_id, references(:workspaces, on_delete: :delete_all), null: false

      add :plugin_installation_id, references(:plugin_installations, on_delete: :delete_all),
        null: false

      add :config, :map, null: false, default: %{}
      add :configured_by, :string
      add :configured_at, :utc_datetime_usec
      add :metadata, :map, null: false, default: %{}

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:plugin_configurations, [:plugin_installation_id])
    create index(:plugin_configurations, [:workspace_id])
  end
end
