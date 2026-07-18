defmodule HydraAgent.Repo.Migrations.HardenSimulationBlueprintIntegrity do
  use Ecto.Migration

  def up do
    create constraint(:simulation_blueprints, :simulation_blueprints_builtin_slug_check,
             check: "built_in = FALSE OR slug IN ('general-agent-simulation', 'decision-replay')"
           )

    execute("""
    CREATE FUNCTION hydra_validate_blueprint_version_scope()
    RETURNS trigger AS $$
    DECLARE
      expected_workspace_id bigint;
      expected_built_in boolean;
    BEGIN
      SELECT workspace_id, built_in
      INTO expected_workspace_id, expected_built_in
      FROM simulation_blueprints
      WHERE id = NEW.blueprint_id;

      IF NOT FOUND THEN
        RAISE EXCEPTION 'simulation blueprint does not exist';
      END IF;

      IF expected_workspace_id IS DISTINCT FROM NEW.workspace_id THEN
        RAISE EXCEPTION 'simulation blueprint version workspace must match its blueprint';
      END IF;

      IF expected_built_in = TRUE AND NEW.created_by_user_id IS NOT NULL THEN
        RAISE EXCEPTION 'built-in simulation blueprint versions cannot have a user author';
      END IF;

      RETURN NEW;
    END;
    $$ LANGUAGE plpgsql;
    """)

    execute("""
    CREATE TRIGGER simulation_blueprint_versions_scope
    BEFORE INSERT ON simulation_blueprint_versions
    FOR EACH ROW EXECUTE FUNCTION hydra_validate_blueprint_version_scope();
    """)

    execute("""
    CREATE FUNCTION hydra_validate_blueprint_active_version()
    RETURNS trigger AS $$
    BEGIN
      IF NEW.active_version_id IS NOT NULL AND NOT EXISTS (
        SELECT 1
        FROM simulation_blueprint_versions
        WHERE id = NEW.active_version_id AND blueprint_id = NEW.id
      ) THEN
        RAISE EXCEPTION 'active simulation blueprint version must belong to its blueprint';
      END IF;

      RETURN NEW;
    END;
    $$ LANGUAGE plpgsql;
    """)

    execute("""
    CREATE TRIGGER simulation_blueprints_active_version_scope
    BEFORE UPDATE OF active_version_id ON simulation_blueprints
    FOR EACH ROW EXECUTE FUNCTION hydra_validate_blueprint_active_version();
    """)
  end

  def down do
    execute(
      "DROP TRIGGER IF EXISTS simulation_blueprints_active_version_scope ON simulation_blueprints"
    )

    execute("DROP FUNCTION IF EXISTS hydra_validate_blueprint_active_version()")

    execute(
      "DROP TRIGGER IF EXISTS simulation_blueprint_versions_scope ON simulation_blueprint_versions"
    )

    execute("DROP FUNCTION IF EXISTS hydra_validate_blueprint_version_scope()")
    drop constraint(:simulation_blueprints, :simulation_blueprints_builtin_slug_check)
  end
end
