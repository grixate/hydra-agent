defmodule HydraAgent.Repo.Migrations.CreateSimulationStudioShell do
  use Ecto.Migration

  def up do
    create table(:simulations) do
      add :workspace_id, references(:workspaces, on_delete: :delete_all), null: false

      add :selected_blueprint_id, references(:simulation_blueprints, on_delete: :restrict),
        null: false

      add :owner_user_id, references(:users, on_delete: :nilify_all)
      add :source_simulation_id, references(:simulations, on_delete: :nilify_all)
      add :legacy_study_id, references(:sim_lab_studies, on_delete: :nilify_all)
      add :title, :string, null: false
      add :question, :text, null: false
      add :locale, :string, null: false, default: "en"
      add :status, :string, null: false, default: "draft"
      add :archived_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create index(:simulations, [:workspace_id, :status, :updated_at])
    create index(:simulations, [:selected_blueprint_id])
    create index(:simulations, [:source_simulation_id])
    create unique_index(:simulations, [:legacy_study_id], where: "legacy_study_id IS NOT NULL")

    create constraint(:simulations, :simulations_status_check,
             check:
               "status IN ('draft','building','needs_attention','ready_to_run','running','analyzing','ready','failed','canceled','archived')"
           )

    create constraint(:simulations, :simulations_locale_check, check: "locale IN ('en','ru')")

    create constraint(:simulations, :simulations_archive_state_check,
             check:
               "(status = 'archived' AND archived_at IS NOT NULL) OR (status <> 'archived' AND archived_at IS NULL)"
           )

    create table(:simulation_versions) do
      add :workspace_id, references(:workspaces, on_delete: :delete_all), null: false
      add :simulation_id, references(:simulations, on_delete: :delete_all), null: false

      add :blueprint_version_id,
          references(:simulation_blueprint_versions, on_delete: :restrict),
          null: false

      add :created_by_user_id, references(:users, on_delete: :nilify_all)
      add :version, :integer, null: false
      add :title, :string, null: false
      add :question, :text, null: false
      add :locale, :string, null: false
      add :normalized_input, :map, null: false, default: %{}
      add :inputs, :map, null: false, default: %{}
      add :instruction_overrides, :map, null: false, default: %{}
      add :research_settings, :map, null: false, default: %{}
      add :population_size, :integer, null: false, default: 5000
      add :execution_mode, :string, null: false, default: "quick"
      add :budget_preset, :string, null: false, default: "quick"
      add :model_routes, :map, null: false, default: %{}
      add :content_hash, :string, null: false

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create unique_index(:simulation_versions, [:simulation_id, :version])
    create unique_index(:simulation_versions, [:simulation_id, :content_hash])
    create index(:simulation_versions, [:workspace_id, :blueprint_version_id])

    create constraint(:simulation_versions, :simulation_versions_positive_version_check,
             check: "version > 0"
           )

    create constraint(:simulation_versions, :simulation_versions_locale_check,
             check: "locale IN ('en','ru')"
           )

    create constraint(:simulation_versions, :simulation_versions_population_size_check,
             check: "population_size BETWEEN 10 AND 100000"
           )

    create constraint(:simulation_versions, :simulation_versions_execution_mode_check,
             check: "execution_mode IN ('quick','balanced','deep')"
           )

    create constraint(:simulation_versions, :simulation_versions_budget_preset_check,
             check: "budget_preset IN ('quick','standard','deep')"
           )

    alter table(:simulations) do
      add :active_version_id, references(:simulation_versions, on_delete: :nilify_all)
    end

    create unique_index(:simulations, [:active_version_id],
             where: "active_version_id IS NOT NULL"
           )

    create table(:simulation_build_stages) do
      add :workspace_id, references(:workspaces, on_delete: :delete_all), null: false
      add :simulation_id, references(:simulations, on_delete: :delete_all), null: false

      add :simulation_version_id, references(:simulation_versions, on_delete: :delete_all),
        null: false

      add :stage, :string, null: false
      add :ordinal, :integer, null: false
      add :status, :string, null: false, default: "pending"
      add :summary, :text
      add :warnings, {:array, :string}, null: false, default: []
      add :started_at, :utc_datetime_usec
      add :completed_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:simulation_build_stages, [:simulation_version_id, :stage])
    create unique_index(:simulation_build_stages, [:simulation_version_id, :ordinal])
    create index(:simulation_build_stages, [:simulation_id, :status])

    create constraint(:simulation_build_stages, :simulation_build_stages_name_check,
             check:
               "stage IN ('understanding_question','finding_context','designing_population','writing_rules','checking_model','preparing_run')"
           )

    create constraint(:simulation_build_stages, :simulation_build_stages_ordinal_check,
             check: "ordinal BETWEEN 1 AND 6"
           )

    create constraint(:simulation_build_stages, :simulation_build_stages_status_check,
             check: "status IN ('pending','running','complete','partial','failed','superseded')"
           )

    execute("""
    CREATE FUNCTION prevent_simulation_version_update()
    RETURNS trigger AS $$
    BEGIN
      RAISE EXCEPTION 'simulation versions are immutable';
    END;
    $$ LANGUAGE plpgsql;
    """)

    execute("""
    CREATE TRIGGER simulation_versions_immutable
    BEFORE UPDATE ON simulation_versions
    FOR EACH ROW EXECUTE FUNCTION prevent_simulation_version_update();
    """)

    execute("""
    CREATE FUNCTION validate_simulation_active_version()
    RETURNS trigger AS $$
    DECLARE
      version_simulation_id bigint;
      version_workspace_id bigint;
      version_blueprint_id bigint;
    BEGIN
      IF NEW.active_version_id IS NULL THEN
        RETURN NEW;
      END IF;

      SELECT sv.simulation_id, sv.workspace_id, bv.blueprint_id
      INTO version_simulation_id, version_workspace_id, version_blueprint_id
      FROM simulation_versions sv
      JOIN simulation_blueprint_versions bv ON bv.id = sv.blueprint_version_id
      WHERE sv.id = NEW.active_version_id;

      IF version_simulation_id IS NULL
         OR version_simulation_id IS DISTINCT FROM NEW.id
         OR version_workspace_id IS DISTINCT FROM NEW.workspace_id
         OR version_blueprint_id IS DISTINCT FROM NEW.selected_blueprint_id THEN
        RAISE EXCEPTION 'active simulation version does not belong to the simulation contract';
      END IF;

      RETURN NEW;
    END;
    $$ LANGUAGE plpgsql;
    """)

    execute("""
    CREATE CONSTRAINT TRIGGER simulations_active_version_integrity
    AFTER INSERT OR UPDATE OF active_version_id, workspace_id, selected_blueprint_id ON simulations
    DEFERRABLE INITIALLY IMMEDIATE
    FOR EACH ROW EXECUTE FUNCTION validate_simulation_active_version();
    """)

    execute("""
    CREATE FUNCTION validate_simulation_version_scope()
    RETURNS trigger AS $$
    DECLARE
      simulation_workspace_id bigint;
      selected_blueprint_id bigint;
      blueprint_id bigint;
      blueprint_workspace_id bigint;
    BEGIN
      SELECT workspace_id, simulations.selected_blueprint_id
      INTO simulation_workspace_id, selected_blueprint_id
      FROM simulations
      WHERE id = NEW.simulation_id;

      SELECT bv.blueprint_id, b.workspace_id
      INTO blueprint_id, blueprint_workspace_id
      FROM simulation_blueprint_versions bv
      JOIN simulation_blueprints b ON b.id = bv.blueprint_id
      WHERE bv.id = NEW.blueprint_version_id;

      IF simulation_workspace_id IS NULL
         OR simulation_workspace_id IS DISTINCT FROM NEW.workspace_id
         OR blueprint_id IS NULL
         OR blueprint_id IS DISTINCT FROM selected_blueprint_id
         OR (blueprint_workspace_id IS NOT NULL AND blueprint_workspace_id IS DISTINCT FROM NEW.workspace_id) THEN
        RAISE EXCEPTION 'simulation version scope does not match its simulation and Blueprint';
      END IF;

      RETURN NEW;
    END;
    $$ LANGUAGE plpgsql;
    """)

    execute("""
    CREATE TRIGGER simulation_versions_scope_integrity
    BEFORE INSERT ON simulation_versions
    FOR EACH ROW EXECUTE FUNCTION validate_simulation_version_scope();
    """)

    execute("""
    CREATE FUNCTION validate_simulation_build_stage_scope()
    RETURNS trigger AS $$
    DECLARE
      version_simulation_id bigint;
      version_workspace_id bigint;
    BEGIN
      SELECT simulation_id, workspace_id
      INTO version_simulation_id, version_workspace_id
      FROM simulation_versions
      WHERE id = NEW.simulation_version_id;

      IF version_simulation_id IS NULL
         OR version_simulation_id IS DISTINCT FROM NEW.simulation_id
         OR version_workspace_id IS DISTINCT FROM NEW.workspace_id THEN
        RAISE EXCEPTION 'build stage scope does not match its simulation version';
      END IF;

      IF TG_OP = 'UPDATE' AND (
        OLD.workspace_id IS DISTINCT FROM NEW.workspace_id OR
        OLD.simulation_id IS DISTINCT FROM NEW.simulation_id OR
        OLD.simulation_version_id IS DISTINCT FROM NEW.simulation_version_id OR
        OLD.stage IS DISTINCT FROM NEW.stage OR
        OLD.ordinal IS DISTINCT FROM NEW.ordinal
      ) THEN
        RAISE EXCEPTION 'build stage identity is immutable';
      END IF;

      RETURN NEW;
    END;
    $$ LANGUAGE plpgsql;
    """)

    execute("""
    CREATE TRIGGER simulation_build_stages_scope_integrity
    BEFORE INSERT OR UPDATE ON simulation_build_stages
    FOR EACH ROW EXECUTE FUNCTION validate_simulation_build_stage_scope();
    """)
  end

  def down do
    execute(
      "DROP TRIGGER IF EXISTS simulation_build_stages_scope_integrity ON simulation_build_stages"
    )

    execute("DROP FUNCTION IF EXISTS validate_simulation_build_stage_scope()")
    execute("DROP TRIGGER IF EXISTS simulation_versions_scope_integrity ON simulation_versions")
    execute("DROP FUNCTION IF EXISTS validate_simulation_version_scope()")
    execute("DROP TRIGGER IF EXISTS simulations_active_version_integrity ON simulations")
    execute("DROP FUNCTION IF EXISTS validate_simulation_active_version()")
    execute("DROP TRIGGER IF EXISTS simulation_versions_immutable ON simulation_versions")
    execute("DROP FUNCTION IF EXISTS prevent_simulation_version_update()")

    drop table(:simulation_build_stages)

    alter table(:simulations) do
      remove :active_version_id
    end

    drop table(:simulation_versions)
    drop table(:simulations)
  end
end
