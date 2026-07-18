defmodule HydraAgent.Repo.Migrations.CreateSimulationScripts do
  use Ecto.Migration

  def up do
    create table(:simulation_scripts) do
      add :workspace_id, references(:workspaces, on_delete: :delete_all), null: false
      add :simulation_id, references(:simulations, on_delete: :delete_all), null: false

      add :simulation_version_id, references(:simulation_versions, on_delete: :delete_all),
        null: false

      add :context_pack_id, references(:simulation_context_packs, on_delete: :restrict),
        null: false

      add :population_model_id,
          references(:simulation_population_models, on_delete: :restrict),
          null: false

      add :created_by_user_id, references(:users, on_delete: :nilify_all)
      add :version, :integer, null: false
      add :schema_version, :integer, null: false, default: 1
      add :compiler_version, :string, null: false
      add :script, :map, null: false
      add :validation_report, :map, null: false, default: %{}
      add :generation_metadata, :map, null: false, default: %{}
      add :status, :string, null: false
      add :content_hash, :string, null: false

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create unique_index(:simulation_scripts, [:simulation_version_id, :version],
             name: :sim_scripts_version_uq
           )

    create unique_index(:simulation_scripts, [:simulation_version_id, :content_hash],
             name: :sim_scripts_hash_uq
           )

    create index(:simulation_scripts, [:simulation_id, :inserted_at])
    create index(:simulation_scripts, [:population_model_id])
    create index(:simulation_scripts, [:workspace_id, :status])

    create constraint(:simulation_scripts, :simulation_scripts_version_check,
             check: "version > 0 AND schema_version = 1"
           )

    create constraint(:simulation_scripts, :simulation_scripts_status_check,
             check: "status IN ('ready','blocked','invalid')"
           )

    create table(:simulation_script_previews) do
      add :workspace_id, references(:workspaces, on_delete: :delete_all), null: false
      add :simulation_id, references(:simulations, on_delete: :delete_all), null: false

      add :simulation_version_id, references(:simulation_versions, on_delete: :delete_all),
        null: false

      add :population_model_id,
          references(:simulation_population_models, on_delete: :restrict),
          null: false

      add :simulation_script_id, references(:simulation_scripts, on_delete: :delete_all),
        null: false

      add :status, :string, null: false
      add :rounds_requested, :integer, null: false, default: 2
      add :rounds_completed, :integer, null: false, default: 0
      add :agent_count, :integer, null: false, default: 0
      add :seed, :bigint, null: false
      add :summary, :map, null: false, default: %{}
      add :errors, {:array, :map}, null: false, default: []
      add :result_hash, :string, null: false

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create unique_index(:simulation_script_previews, [:simulation_script_id],
             name: :sim_script_previews_script_uq
           )

    create index(:simulation_script_previews, [:simulation_id, :inserted_at])

    create constraint(:simulation_script_previews, :simulation_script_previews_status_check,
             check: "status IN ('passed','failed')"
           )

    create constraint(:simulation_script_previews, :simulation_script_previews_bounds_check,
             check:
               "rounds_requested BETWEEN 1 AND 2 AND rounds_completed BETWEEN 0 AND rounds_requested AND agent_count BETWEEN 0 AND 32 AND seed >= 0"
           )

    alter table(:simulations) do
      add :active_script_id, references(:simulation_scripts, on_delete: :nilify_all)
    end

    create unique_index(:simulations, [:active_script_id], where: "active_script_id IS NOT NULL")

    execute("""
    CREATE FUNCTION prevent_simulation_script_update()
    RETURNS trigger AS $$
    BEGIN
      RAISE EXCEPTION 'simulation scripts are immutable';
    END;
    $$ LANGUAGE plpgsql;
    """)

    execute("""
    CREATE TRIGGER simulation_scripts_immutable
    BEFORE UPDATE ON simulation_scripts
    FOR EACH ROW EXECUTE FUNCTION prevent_simulation_script_update();
    """)

    execute("""
    CREATE FUNCTION validate_simulation_script_scope()
    RETURNS trigger AS $$
    DECLARE
      model_simulation_id bigint;
      model_workspace_id bigint;
      model_version_id bigint;
      model_context_id bigint;
    BEGIN
      SELECT simulation_id, workspace_id, simulation_version_id, context_pack_id
      INTO model_simulation_id, model_workspace_id, model_version_id, model_context_id
      FROM simulation_population_models
      WHERE id = NEW.population_model_id;

      IF model_simulation_id IS NULL
         OR model_simulation_id IS DISTINCT FROM NEW.simulation_id
         OR model_workspace_id IS DISTINCT FROM NEW.workspace_id
         OR model_version_id IS DISTINCT FROM NEW.simulation_version_id
         OR model_context_id IS DISTINCT FROM NEW.context_pack_id THEN
        RAISE EXCEPTION 'simulation script scope does not match its population model';
      END IF;

      IF NOT hydra_simulation_user_authorized(NEW.created_by_user_id, NEW.workspace_id) THEN
        RAISE EXCEPTION 'simulation script author is not authorized for the workspace';
      END IF;

      RETURN NEW;
    END;
    $$ LANGUAGE plpgsql;
    """)

    execute("""
    CREATE TRIGGER simulation_scripts_scope_integrity
    BEFORE INSERT ON simulation_scripts
    FOR EACH ROW EXECUTE FUNCTION validate_simulation_script_scope();
    """)

    execute("""
    CREATE FUNCTION prevent_simulation_script_preview_update()
    RETURNS trigger AS $$
    BEGIN
      RAISE EXCEPTION 'simulation script previews are immutable';
    END;
    $$ LANGUAGE plpgsql;
    """)

    execute("""
    CREATE TRIGGER simulation_script_previews_immutable
    BEFORE UPDATE ON simulation_script_previews
    FOR EACH ROW EXECUTE FUNCTION prevent_simulation_script_preview_update();
    """)

    execute("""
    CREATE FUNCTION validate_simulation_script_preview_scope()
    RETURNS trigger AS $$
    DECLARE
      script_simulation_id bigint;
      script_workspace_id bigint;
      script_version_id bigint;
      script_population_id bigint;
    BEGIN
      SELECT simulation_id, workspace_id, simulation_version_id, population_model_id
      INTO script_simulation_id, script_workspace_id, script_version_id, script_population_id
      FROM simulation_scripts
      WHERE id = NEW.simulation_script_id;

      IF script_simulation_id IS NULL
         OR script_simulation_id IS DISTINCT FROM NEW.simulation_id
         OR script_workspace_id IS DISTINCT FROM NEW.workspace_id
         OR script_version_id IS DISTINCT FROM NEW.simulation_version_id
         OR script_population_id IS DISTINCT FROM NEW.population_model_id THEN
        RAISE EXCEPTION 'script preview scope does not match its script';
      END IF;

      RETURN NEW;
    END;
    $$ LANGUAGE plpgsql;
    """)

    execute("""
    CREATE TRIGGER simulation_script_previews_scope_integrity
    BEFORE INSERT ON simulation_script_previews
    FOR EACH ROW EXECUTE FUNCTION validate_simulation_script_preview_scope();
    """)

    execute("""
    CREATE FUNCTION validate_simulation_active_script()
    RETURNS trigger AS $$
    DECLARE
      script_simulation_id bigint;
      script_workspace_id bigint;
      script_version_id bigint;
      script_context_id bigint;
      script_population_id bigint;
    BEGIN
      IF NEW.active_script_id IS NULL THEN
        RETURN NEW;
      END IF;

      SELECT simulation_id, workspace_id, simulation_version_id, context_pack_id, population_model_id
      INTO script_simulation_id, script_workspace_id, script_version_id, script_context_id, script_population_id
      FROM simulation_scripts
      WHERE id = NEW.active_script_id;

      IF script_simulation_id IS NULL
         OR script_simulation_id IS DISTINCT FROM NEW.id
         OR script_workspace_id IS DISTINCT FROM NEW.workspace_id
         OR script_version_id IS DISTINCT FROM NEW.active_version_id
         OR script_context_id IS DISTINCT FROM NEW.active_context_pack_id
         OR script_population_id IS DISTINCT FROM NEW.active_population_model_id THEN
        RAISE EXCEPTION 'active script does not belong to the active population model';
      END IF;

      RETURN NEW;
    END;
    $$ LANGUAGE plpgsql;
    """)

    execute("""
    CREATE CONSTRAINT TRIGGER simulations_active_script_integrity
    AFTER INSERT OR UPDATE OF active_script_id, active_population_model_id, active_context_pack_id, active_version_id, workspace_id ON simulations
    DEFERRABLE INITIALLY IMMEDIATE
    FOR EACH ROW EXECUTE FUNCTION validate_simulation_active_script();
    """)
  end

  def down do
    execute("DROP TRIGGER IF EXISTS simulations_active_script_integrity ON simulations")
    execute("DROP FUNCTION IF EXISTS validate_simulation_active_script()")

    execute(
      "DROP TRIGGER IF EXISTS simulation_script_previews_scope_integrity ON simulation_script_previews"
    )

    execute("DROP FUNCTION IF EXISTS validate_simulation_script_preview_scope()")

    execute(
      "DROP TRIGGER IF EXISTS simulation_script_previews_immutable ON simulation_script_previews"
    )

    execute("DROP FUNCTION IF EXISTS prevent_simulation_script_preview_update()")
    execute("DROP TRIGGER IF EXISTS simulation_scripts_scope_integrity ON simulation_scripts")
    execute("DROP FUNCTION IF EXISTS validate_simulation_script_scope()")
    execute("DROP TRIGGER IF EXISTS simulation_scripts_immutable ON simulation_scripts")
    execute("DROP FUNCTION IF EXISTS prevent_simulation_script_update()")

    alter table(:simulations) do
      remove :active_script_id
    end

    drop table(:simulation_script_previews)
    drop table(:simulation_scripts)
  end
end
