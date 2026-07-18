defmodule HydraAgent.Repo.Migrations.CreateSimulationBlueprints do
  use Ecto.Migration

  def up do
    create table(:simulation_blueprints) do
      add :workspace_id, references(:workspaces, on_delete: :delete_all)
      add :owner_user_id, references(:users, on_delete: :nilify_all)
      add :source_blueprint_id, references(:simulation_blueprints, on_delete: :nilify_all)
      add :slug, :string, null: false
      add :name, :map, null: false, default: %{}
      add :description, :map, null: false, default: %{}
      add :status, :string, null: false, default: "active"
      add :built_in, :boolean, null: false, default: false
      add :origin, :map, null: false, default: %{}

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:simulation_blueprints, [:slug],
             where: "workspace_id IS NULL",
             name: :simulation_blueprints_system_slug_index
           )

    create unique_index(:simulation_blueprints, [:workspace_id, :slug],
             where: "workspace_id IS NOT NULL",
             name: :simulation_blueprints_workspace_slug_index
           )

    create index(:simulation_blueprints, [:workspace_id, :status])
    create index(:simulation_blueprints, [:source_blueprint_id])

    create constraint(:simulation_blueprints, :simulation_blueprints_status_check,
             check: "status IN ('active', 'archived')"
           )

    create constraint(:simulation_blueprints, :simulation_blueprints_scope_check,
             check:
               "(built_in = TRUE AND workspace_id IS NULL AND owner_user_id IS NULL) OR " <>
                 "(built_in = FALSE AND workspace_id IS NOT NULL)"
           )

    create table(:simulation_blueprint_versions) do
      add :workspace_id, references(:workspaces, on_delete: :delete_all)

      add :blueprint_id, references(:simulation_blueprints, on_delete: :delete_all), null: false

      add :created_by_user_id, references(:users, on_delete: :nilify_all)
      add :version, :string, null: false
      add :manifest, :map, null: false, default: %{}
      add :instructions, :map, null: false, default: %{}
      add :schemas, :map, null: false, default: %{}
      add :examples, :map, null: false, default: %{}
      add :readme, :text, null: false, default: ""
      add :capability_requirements, :map, null: false, default: %{}
      add :content_hash, :string, null: false
      add :validation_status, :string, null: false, default: "valid"
      add :validation_errors, {:array, :map}, null: false, default: []
      add :compatibility_warnings, {:array, :string}, null: false, default: []

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create unique_index(:simulation_blueprint_versions, [:blueprint_id, :version])
    create unique_index(:simulation_blueprint_versions, [:blueprint_id, :content_hash])
    create index(:simulation_blueprint_versions, [:workspace_id, :inserted_at])
    create index(:simulation_blueprint_versions, [:created_by_user_id])

    create constraint(:simulation_blueprint_versions, :simulation_blueprint_versions_status_check,
             check: "validation_status IN ('valid', 'invalid')"
           )

    alter table(:simulation_blueprints) do
      add :active_version_id,
          references(:simulation_blueprint_versions, on_delete: :nilify_all)
    end

    create index(:simulation_blueprints, [:active_version_id])

    execute("""
    CREATE FUNCTION hydra_prevent_blueprint_version_update()
    RETURNS trigger AS $$
    BEGIN
      RAISE EXCEPTION 'simulation blueprint versions are immutable';
    END;
    $$ LANGUAGE plpgsql;
    """)

    execute("""
    CREATE TRIGGER simulation_blueprint_versions_immutable
    BEFORE UPDATE ON simulation_blueprint_versions
    FOR EACH ROW EXECUTE FUNCTION hydra_prevent_blueprint_version_update();
    """)
  end

  def down do
    execute(
      "DROP TRIGGER IF EXISTS simulation_blueprint_versions_immutable ON simulation_blueprint_versions"
    )

    execute("DROP FUNCTION IF EXISTS hydra_prevent_blueprint_version_update()")

    alter table(:simulation_blueprints) do
      remove :active_version_id
    end

    drop table(:simulation_blueprint_versions)
    drop table(:simulation_blueprints)
  end
end
