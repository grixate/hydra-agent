defmodule HydraAgent.Repo.Migrations.CreatePlugins do
  use Ecto.Migration

  def change do
    create table(:plugin_installations) do
      add :workspace_id, references(:workspaces, on_delete: :delete_all), null: false
      add :slug, :string, null: false
      add :name, :string, null: false
      add :version, :string, null: false
      add :description, :text
      add :status, :string, null: false, default: "installed"
      add :source_type, :string, null: false
      add :source_url, :text
      add :source_path, :text
      add :source_ref, :string
      add :trust_level, :string, null: false, default: "external"
      add :manifest, :map, null: false, default: %{}
      add :manifest_digest, :string, null: false
      add :permissions, :map, null: false, default: %{}
      add :env_refs, {:array, :string}, null: false, default: []
      add :last_error, :map, null: false, default: %{}
      add :approved_by, :string
      add :approved_at, :utc_datetime_usec
      add :metadata, :map, null: false, default: %{}

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:plugin_installations, [:workspace_id, :slug])
    create index(:plugin_installations, [:workspace_id, :status])
    create index(:plugin_installations, [:workspace_id, :source_type])

    create table(:plugin_capabilities) do
      add :workspace_id, references(:workspaces, on_delete: :delete_all), null: false

      add :plugin_installation_id, references(:plugin_installations, on_delete: :delete_all),
        null: false

      add :kind, :string, null: false
      add :name, :string, null: false
      add :status, :string, null: false, default: "enabled"
      add :side_effect_class, :string
      add :spec, :map, null: false, default: %{}
      add :metadata, :map, null: false, default: %{}

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:plugin_capabilities, [:workspace_id, :kind, :name])
    create index(:plugin_capabilities, [:plugin_installation_id])
    create index(:plugin_capabilities, [:workspace_id, :kind, :status])

    create table(:plugin_events) do
      add :workspace_id, references(:workspaces, on_delete: :delete_all), null: false
      add :plugin_installation_id, references(:plugin_installations, on_delete: :nilify_all)
      add :event_type, :string, null: false
      add :actor, :string, null: false, default: "operator"
      add :summary, :text, null: false
      add :payload, :map, null: false, default: %{}

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create index(:plugin_events, [:workspace_id, :inserted_at])
    create index(:plugin_events, [:plugin_installation_id])
  end
end
