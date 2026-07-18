defmodule HydraAgent.Repo.Migrations.HardenSimulationStudioIntegrity do
  use Ecto.Migration

  def up do
    execute("""
    CREATE FUNCTION hydra_simulation_user_authorized(candidate_user_id bigint, candidate_workspace_id bigint)
    RETURNS boolean AS $$
      SELECT candidate_user_id IS NULL OR EXISTS (
        SELECT 1
        FROM users u
        WHERE u.id = candidate_user_id
          AND u.status = 'active'
          AND (
            u.global_role = 'system_admin'
            OR EXISTS (
              SELECT 1
              FROM workspace_memberships membership
              WHERE membership.user_id = candidate_user_id
                AND membership.workspace_id = candidate_workspace_id
                AND membership.role IN ('researcher', 'admin', 'owner')
            )
          )
      );
    $$ LANGUAGE sql STABLE;
    """)

    execute("""
    CREATE FUNCTION hydra_validate_simulation_scope()
    RETURNS trigger AS $$
    BEGIN
      IF NOT hydra_simulation_user_authorized(NEW.owner_user_id, NEW.workspace_id) THEN
        RAISE EXCEPTION 'simulation owner is not authorized for the workspace';
      END IF;

      IF NOT EXISTS (
        SELECT 1
        FROM simulation_blueprints blueprint
        WHERE blueprint.id = NEW.selected_blueprint_id
          AND blueprint.status = 'active'
          AND (blueprint.built_in = TRUE OR blueprint.workspace_id = NEW.workspace_id)
      ) THEN
        RAISE EXCEPTION 'selected Blueprint is not available in the simulation workspace';
      END IF;

      IF NEW.source_simulation_id IS NOT NULL AND NOT EXISTS (
        SELECT 1
        FROM simulations source
        WHERE source.id = NEW.source_simulation_id
          AND source.workspace_id = NEW.workspace_id
      ) THEN
        RAISE EXCEPTION 'source simulation must belong to the same workspace';
      END IF;

      IF NEW.legacy_study_id IS NOT NULL AND NOT EXISTS (
        SELECT 1
        FROM sim_lab_studies study
        WHERE study.id = NEW.legacy_study_id
          AND study.workspace_id = NEW.workspace_id
      ) THEN
        RAISE EXCEPTION 'legacy study must belong to the same workspace';
      END IF;

      RETURN NEW;
    END;
    $$ LANGUAGE plpgsql;
    """)

    execute("""
    CREATE TRIGGER simulations_scope_integrity
    BEFORE INSERT OR UPDATE OF workspace_id, owner_user_id, selected_blueprint_id, source_simulation_id, legacy_study_id
    ON simulations
    FOR EACH ROW EXECUTE FUNCTION hydra_validate_simulation_scope();
    """)

    execute("""
    CREATE FUNCTION hydra_validate_simulation_version_author()
    RETURNS trigger AS $$
    BEGIN
      IF NOT hydra_simulation_user_authorized(NEW.created_by_user_id, NEW.workspace_id) THEN
        RAISE EXCEPTION 'simulation version author is not authorized for the workspace';
      END IF;

      RETURN NEW;
    END;
    $$ LANGUAGE plpgsql;
    """)

    execute("""
    CREATE TRIGGER simulation_versions_author_integrity
    BEFORE INSERT ON simulation_versions
    FOR EACH ROW EXECUTE FUNCTION hydra_validate_simulation_version_author();
    """)
  end

  def down do
    execute("DROP TRIGGER IF EXISTS simulation_versions_author_integrity ON simulation_versions")
    execute("DROP FUNCTION IF EXISTS hydra_validate_simulation_version_author()")
    execute("DROP TRIGGER IF EXISTS simulations_scope_integrity ON simulations")
    execute("DROP FUNCTION IF EXISTS hydra_validate_simulation_scope()")

    execute("DROP FUNCTION IF EXISTS hydra_simulation_user_authorized(bigint, bigint)")
  end
end
