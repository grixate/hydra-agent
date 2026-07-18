defmodule HydraAgent.Repo.Migrations.CreateSimulationPopulationModels do
  use Ecto.Migration

  def up do
    create table(:simulation_population_models) do
      add :workspace_id, references(:workspaces, on_delete: :delete_all), null: false
      add :simulation_id, references(:simulations, on_delete: :delete_all), null: false

      add :simulation_version_id, references(:simulation_versions, on_delete: :delete_all),
        null: false

      add :context_pack_id, references(:simulation_context_packs, on_delete: :restrict),
        null: false

      add :created_by_user_id, references(:users, on_delete: :nilify_all)
      add :version, :integer, null: false
      add :schema_version, :integer, null: false, default: 1
      add :compiler_version, :string, null: false
      add :seed, :bigint, null: false
      add :population_size, :integer, null: false
      add :agent_types, {:array, :map}, null: false, default: []
      add :archetypes, {:array, :map}, null: false, default: []
      add :conditional_distributions, {:array, :map}, null: false, default: []
      add :relationship_rules, {:array, :map}, null: false, default: []
      add :representative_rules, :map, null: false, default: %{}
      add :imported_agents, {:array, :map}, null: false, default: []
      add :imported_relationships, {:array, :map}, null: false, default: []
      add :import_summary, :map, null: false, default: %{}
      add :compile_summary, :map, null: false, default: %{}
      add :generation_metadata, :map, null: false, default: %{}
      add :status, :string, null: false
      add :content_hash, :string, null: false

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create unique_index(:simulation_population_models, [:simulation_version_id, :version],
             name: :sim_pop_models_version_uq
           )

    create unique_index(
             :simulation_population_models,
             [
               :simulation_version_id,
               :content_hash
             ],
             name: :sim_pop_models_hash_uq
           )

    create index(:simulation_population_models, [:simulation_id, :inserted_at])
    create index(:simulation_population_models, [:context_pack_id])
    create index(:simulation_population_models, [:workspace_id, :status])

    create constraint(:simulation_population_models, :simulation_population_models_version_check,
             check: "version > 0 AND schema_version = 1"
           )

    create constraint(:simulation_population_models, :simulation_population_models_size_check,
             check: "population_size BETWEEN 10 AND 100000"
           )

    create constraint(:simulation_population_models, :simulation_population_models_seed_check,
             check: "seed >= 0"
           )

    create constraint(:simulation_population_models, :simulation_population_models_status_check,
             check: "status IN ('ready','partial','invalid')"
           )

    alter table(:simulations) do
      add :active_population_model_id,
          references(:simulation_population_models, on_delete: :nilify_all)
    end

    create unique_index(:simulations, [:active_population_model_id],
             where: "active_population_model_id IS NOT NULL"
           )

    create table(:simulation_persona_projections) do
      add :workspace_id, references(:workspaces, on_delete: :delete_all), null: false
      add :simulation_id, references(:simulations, on_delete: :delete_all), null: false

      add :simulation_version_id, references(:simulation_versions, on_delete: :delete_all),
        null: false

      add :population_model_id,
          references(:simulation_population_models, on_delete: :delete_all),
          null: false

      add :created_by_user_id, references(:users, on_delete: :nilify_all)
      add :agent_id, :string, null: false
      add :archetype_id, :string, null: false
      add :projection, :map, null: false, default: %{}
      add :prose, :text, null: false
      add :generated_by, :string, null: false, default: "deterministic"
      add :generated_lazily, :boolean, null: false, default: true
      add :content_hash, :string, null: false

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create unique_index(:simulation_persona_projections, [:population_model_id, :agent_id],
             name: :sim_persona_agent_uq
           )

    create index(:simulation_persona_projections, [:simulation_id, :inserted_at])

    create constraint(
             :simulation_persona_projections,
             :simulation_persona_projections_generator_check,
             check: "generated_by IN ('deterministic','model')"
           )

    execute("""
    CREATE FUNCTION prevent_simulation_population_model_update()
    RETURNS trigger AS $$
    BEGIN
      RAISE EXCEPTION 'simulation population models are immutable';
    END;
    $$ LANGUAGE plpgsql;
    """)

    execute("""
    CREATE TRIGGER simulation_population_models_immutable
    BEFORE UPDATE ON simulation_population_models
    FOR EACH ROW EXECUTE FUNCTION prevent_simulation_population_model_update();
    """)

    execute("""
    CREATE FUNCTION validate_simulation_population_model_scope()
    RETURNS trigger AS $$
    DECLARE
      version_simulation_id bigint;
      version_workspace_id bigint;
      pack_simulation_id bigint;
      pack_workspace_id bigint;
      pack_version_id bigint;
    BEGIN
      SELECT simulation_id, workspace_id
      INTO version_simulation_id, version_workspace_id
      FROM simulation_versions
      WHERE id = NEW.simulation_version_id;

      SELECT simulation_id, workspace_id, simulation_version_id
      INTO pack_simulation_id, pack_workspace_id, pack_version_id
      FROM simulation_context_packs
      WHERE id = NEW.context_pack_id;

      IF version_simulation_id IS NULL
         OR version_simulation_id IS DISTINCT FROM NEW.simulation_id
         OR version_workspace_id IS DISTINCT FROM NEW.workspace_id
         OR pack_simulation_id IS NULL
         OR pack_simulation_id IS DISTINCT FROM NEW.simulation_id
         OR pack_workspace_id IS DISTINCT FROM NEW.workspace_id
         OR pack_version_id IS DISTINCT FROM NEW.simulation_version_id THEN
        RAISE EXCEPTION 'population model scope does not match its context and simulation version';
      END IF;

      IF NOT hydra_simulation_user_authorized(NEW.created_by_user_id, NEW.workspace_id) THEN
        RAISE EXCEPTION 'population model author is not authorized for the workspace';
      END IF;

      RETURN NEW;
    END;
    $$ LANGUAGE plpgsql;
    """)

    execute("""
    CREATE TRIGGER simulation_population_models_scope_integrity
    BEFORE INSERT ON simulation_population_models
    FOR EACH ROW EXECUTE FUNCTION validate_simulation_population_model_scope();
    """)

    execute("""
    CREATE FUNCTION validate_simulation_active_population_model()
    RETURNS trigger AS $$
    DECLARE
      model_simulation_id bigint;
      model_workspace_id bigint;
      model_version_id bigint;
      model_context_pack_id bigint;
    BEGIN
      IF NEW.active_population_model_id IS NULL THEN
        RETURN NEW;
      END IF;

      SELECT simulation_id, workspace_id, simulation_version_id, context_pack_id
      INTO model_simulation_id, model_workspace_id, model_version_id, model_context_pack_id
      FROM simulation_population_models
      WHERE id = NEW.active_population_model_id;

      IF model_simulation_id IS NULL
         OR model_simulation_id IS DISTINCT FROM NEW.id
         OR model_workspace_id IS DISTINCT FROM NEW.workspace_id
         OR model_version_id IS DISTINCT FROM NEW.active_version_id
         OR model_context_pack_id IS DISTINCT FROM NEW.active_context_pack_id THEN
        RAISE EXCEPTION 'active population model does not belong to the active context pack';
      END IF;

      RETURN NEW;
    END;
    $$ LANGUAGE plpgsql;
    """)

    execute("""
    CREATE CONSTRAINT TRIGGER simulations_active_population_model_integrity
    AFTER INSERT OR UPDATE OF active_population_model_id, active_context_pack_id, active_version_id, workspace_id ON simulations
    DEFERRABLE INITIALLY IMMEDIATE
    FOR EACH ROW EXECUTE FUNCTION validate_simulation_active_population_model();
    """)

    execute("""
    CREATE FUNCTION prevent_simulation_persona_projection_update()
    RETURNS trigger AS $$
    BEGIN
      RAISE EXCEPTION 'simulation persona projections are immutable';
    END;
    $$ LANGUAGE plpgsql;
    """)

    execute("""
    CREATE TRIGGER simulation_persona_projections_immutable
    BEFORE UPDATE ON simulation_persona_projections
    FOR EACH ROW EXECUTE FUNCTION prevent_simulation_persona_projection_update();
    """)

    execute("""
    CREATE FUNCTION validate_simulation_persona_projection_scope()
    RETURNS trigger AS $$
    DECLARE
      model_simulation_id bigint;
      model_workspace_id bigint;
      model_version_id bigint;
    BEGIN
      SELECT simulation_id, workspace_id, simulation_version_id
      INTO model_simulation_id, model_workspace_id, model_version_id
      FROM simulation_population_models
      WHERE id = NEW.population_model_id;

      IF model_simulation_id IS NULL
         OR model_simulation_id IS DISTINCT FROM NEW.simulation_id
         OR model_workspace_id IS DISTINCT FROM NEW.workspace_id
         OR model_version_id IS DISTINCT FROM NEW.simulation_version_id THEN
        RAISE EXCEPTION 'persona projection scope does not match its population model';
      END IF;

      IF NOT hydra_simulation_user_authorized(NEW.created_by_user_id, NEW.workspace_id) THEN
        RAISE EXCEPTION 'persona projection author is not authorized for the workspace';
      END IF;

      RETURN NEW;
    END;
    $$ LANGUAGE plpgsql;
    """)

    execute("""
    CREATE TRIGGER simulation_persona_projections_scope_integrity
    BEFORE INSERT ON simulation_persona_projections
    FOR EACH ROW EXECUTE FUNCTION validate_simulation_persona_projection_scope();
    """)
  end

  def down do
    execute(
      "DROP TRIGGER IF EXISTS simulation_persona_projections_scope_integrity ON simulation_persona_projections"
    )

    execute("DROP FUNCTION IF EXISTS validate_simulation_persona_projection_scope()")

    execute(
      "DROP TRIGGER IF EXISTS simulation_persona_projections_immutable ON simulation_persona_projections"
    )

    execute("DROP FUNCTION IF EXISTS prevent_simulation_persona_projection_update()")

    execute("DROP TRIGGER IF EXISTS simulations_active_population_model_integrity ON simulations")

    execute("DROP FUNCTION IF EXISTS validate_simulation_active_population_model()")

    execute(
      "DROP TRIGGER IF EXISTS simulation_population_models_scope_integrity ON simulation_population_models"
    )

    execute("DROP FUNCTION IF EXISTS validate_simulation_population_model_scope()")

    execute(
      "DROP TRIGGER IF EXISTS simulation_population_models_immutable ON simulation_population_models"
    )

    execute("DROP FUNCTION IF EXISTS prevent_simulation_population_model_update()")

    drop table(:simulation_persona_projections)

    alter table(:simulations) do
      remove :active_population_model_id
    end

    drop table(:simulation_population_models)
  end
end
