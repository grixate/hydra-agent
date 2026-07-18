defmodule HydraAgent.Repo.Migrations.CreateSimulationContextPacks do
  use Ecto.Migration

  def up do
    create table(:simulation_context_packs) do
      add :workspace_id, references(:workspaces, on_delete: :delete_all), null: false
      add :simulation_id, references(:simulations, on_delete: :delete_all), null: false

      add :simulation_version_id, references(:simulation_versions, on_delete: :delete_all),
        null: false

      add :created_by_user_id, references(:users, on_delete: :nilify_all)
      add :version, :integer, null: false
      add :interpretation, :map, null: false, default: %{}
      add :scope, :map, null: false, default: %{}
      add :research_plan, {:array, :map}, null: false, default: []
      add :sources, {:array, :map}, null: false, default: []
      add :claims, {:array, :map}, null: false, default: []
      add :assumptions, {:array, :map}, null: false, default: []
      add :gaps, {:array, :map}, null: false, default: []
      add :research_metadata, :map, null: false, default: %{}
      add :historical_cutoff, :date
      add :status, :string, null: false
      add :confidence, :float, null: false
      add :content_hash, :string, null: false

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create unique_index(:simulation_context_packs, [:simulation_version_id, :version])
    create unique_index(:simulation_context_packs, [:simulation_version_id, :content_hash])
    create index(:simulation_context_packs, [:simulation_id, :inserted_at])
    create index(:simulation_context_packs, [:workspace_id, :status])

    create constraint(:simulation_context_packs, :simulation_context_packs_version_check,
             check: "version > 0"
           )

    create constraint(:simulation_context_packs, :simulation_context_packs_status_check,
             check: "status IN ('ready','partial','failed')"
           )

    create constraint(:simulation_context_packs, :simulation_context_packs_confidence_check,
             check: "confidence BETWEEN 0.0 AND 1.0"
           )

    alter table(:simulations) do
      add :active_context_pack_id,
          references(:simulation_context_packs, on_delete: :nilify_all)
    end

    create unique_index(:simulations, [:active_context_pack_id],
             where: "active_context_pack_id IS NOT NULL"
           )

    create table(:simulation_context_research_runs) do
      add :workspace_id, references(:workspaces, on_delete: :delete_all), null: false
      add :simulation_id, references(:simulations, on_delete: :delete_all), null: false

      add :simulation_version_id, references(:simulation_versions, on_delete: :delete_all),
        null: false

      add :context_pack_id, references(:simulation_context_packs, on_delete: :nilify_all)
      add :provider, :string, null: false
      add :status, :string, null: false, default: "queued"
      add :input_snapshot, :map, null: false, default: %{}
      add :planned_lanes, :integer, null: false, default: 0
      add :completed_lanes, :integer, null: false, default: 0
      add :failed_lanes, :integer, null: false, default: 0
      add :failure_reason, :text
      add :started_at, :utc_datetime_usec
      add :completed_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create index(:simulation_context_research_runs, [:simulation_id, :inserted_at])
    create index(:simulation_context_research_runs, [:workspace_id, :status])

    create constraint(
             :simulation_context_research_runs,
             :simulation_context_research_runs_provider_check,
             check: "provider IN ('web_search','mock')"
           )

    create constraint(
             :simulation_context_research_runs,
             :simulation_context_research_runs_status_check,
             check: "status IN ('queued','running','completed','failed','cancelled')"
           )

    create constraint(
             :simulation_context_research_runs,
             :simulation_context_research_runs_lane_counts_check,
             check:
               "planned_lanes >= 0 AND completed_lanes >= 0 AND failed_lanes >= 0 AND completed_lanes + failed_lanes <= planned_lanes"
           )

    execute("""
    CREATE FUNCTION prevent_simulation_context_pack_update()
    RETURNS trigger AS $$
    BEGIN
      RAISE EXCEPTION 'simulation context packs are immutable';
    END;
    $$ LANGUAGE plpgsql;
    """)

    execute("""
    CREATE TRIGGER simulation_context_packs_immutable
    BEFORE UPDATE ON simulation_context_packs
    FOR EACH ROW EXECUTE FUNCTION prevent_simulation_context_pack_update();
    """)

    execute("""
    CREATE FUNCTION validate_simulation_context_pack_scope()
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
        RAISE EXCEPTION 'context pack scope does not match its simulation version';
      END IF;

      IF NOT hydra_simulation_user_authorized(NEW.created_by_user_id, NEW.workspace_id) THEN
        RAISE EXCEPTION 'context pack author is not authorized for the workspace';
      END IF;

      RETURN NEW;
    END;
    $$ LANGUAGE plpgsql;
    """)

    execute("""
    CREATE TRIGGER simulation_context_packs_scope_integrity
    BEFORE INSERT ON simulation_context_packs
    FOR EACH ROW EXECUTE FUNCTION validate_simulation_context_pack_scope();
    """)

    execute("""
    CREATE FUNCTION validate_simulation_active_context_pack()
    RETURNS trigger AS $$
    DECLARE
      pack_simulation_id bigint;
      pack_workspace_id bigint;
      pack_simulation_version_id bigint;
    BEGIN
      IF NEW.active_context_pack_id IS NULL THEN
        RETURN NEW;
      END IF;

      SELECT simulation_id, workspace_id, simulation_version_id
      INTO pack_simulation_id, pack_workspace_id, pack_simulation_version_id
      FROM simulation_context_packs
      WHERE id = NEW.active_context_pack_id;

      IF pack_simulation_id IS NULL
         OR pack_simulation_id IS DISTINCT FROM NEW.id
         OR pack_workspace_id IS DISTINCT FROM NEW.workspace_id
         OR pack_simulation_version_id IS DISTINCT FROM NEW.active_version_id THEN
        RAISE EXCEPTION 'active context pack does not belong to the active simulation version';
      END IF;

      RETURN NEW;
    END;
    $$ LANGUAGE plpgsql;
    """)

    execute("""
    CREATE CONSTRAINT TRIGGER simulations_active_context_pack_integrity
    AFTER INSERT OR UPDATE OF active_context_pack_id, active_version_id, workspace_id ON simulations
    DEFERRABLE INITIALLY IMMEDIATE
    FOR EACH ROW EXECUTE FUNCTION validate_simulation_active_context_pack();
    """)

    execute("""
    CREATE FUNCTION validate_simulation_context_research_run_scope()
    RETURNS trigger AS $$
    DECLARE
      version_simulation_id bigint;
      version_workspace_id bigint;
      pack_simulation_id bigint;
      pack_version_id bigint;
    BEGIN
      SELECT simulation_id, workspace_id
      INTO version_simulation_id, version_workspace_id
      FROM simulation_versions
      WHERE id = NEW.simulation_version_id;

      IF version_simulation_id IS NULL
         OR version_simulation_id IS DISTINCT FROM NEW.simulation_id
         OR version_workspace_id IS DISTINCT FROM NEW.workspace_id THEN
        RAISE EXCEPTION 'context research run scope does not match its simulation version';
      END IF;

      IF NEW.context_pack_id IS NOT NULL THEN
        SELECT simulation_id, simulation_version_id
        INTO pack_simulation_id, pack_version_id
        FROM simulation_context_packs
        WHERE id = NEW.context_pack_id;

        IF pack_simulation_id IS NULL
           OR pack_simulation_id IS DISTINCT FROM NEW.simulation_id
           OR pack_version_id IS DISTINCT FROM NEW.simulation_version_id THEN
          RAISE EXCEPTION 'context research result does not belong to the run scope';
        END IF;
      END IF;

      IF TG_OP = 'UPDATE' AND (
        OLD.workspace_id IS DISTINCT FROM NEW.workspace_id OR
        OLD.simulation_id IS DISTINCT FROM NEW.simulation_id OR
        OLD.simulation_version_id IS DISTINCT FROM NEW.simulation_version_id OR
        OLD.provider IS DISTINCT FROM NEW.provider OR
        OLD.input_snapshot IS DISTINCT FROM NEW.input_snapshot
      ) THEN
        RAISE EXCEPTION 'context research run identity is immutable';
      END IF;

      RETURN NEW;
    END;
    $$ LANGUAGE plpgsql;
    """)

    execute("""
    CREATE TRIGGER simulation_context_research_runs_scope_integrity
    BEFORE INSERT OR UPDATE ON simulation_context_research_runs
    FOR EACH ROW EXECUTE FUNCTION validate_simulation_context_research_run_scope();
    """)
  end

  def down do
    execute(
      "DROP TRIGGER IF EXISTS simulation_context_research_runs_scope_integrity ON simulation_context_research_runs"
    )

    execute("DROP FUNCTION IF EXISTS validate_simulation_context_research_run_scope()")
    execute("DROP TRIGGER IF EXISTS simulations_active_context_pack_integrity ON simulations")
    execute("DROP FUNCTION IF EXISTS validate_simulation_active_context_pack()")

    execute(
      "DROP TRIGGER IF EXISTS simulation_context_packs_scope_integrity ON simulation_context_packs"
    )

    execute("DROP FUNCTION IF EXISTS validate_simulation_context_pack_scope()")

    execute(
      "DROP TRIGGER IF EXISTS simulation_context_packs_immutable ON simulation_context_packs"
    )

    execute("DROP FUNCTION IF EXISTS prevent_simulation_context_pack_update()")

    drop table(:simulation_context_research_runs)

    alter table(:simulations) do
      remove :active_context_pack_id
    end

    drop table(:simulation_context_packs)
  end
end
