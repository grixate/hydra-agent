defmodule HydraAgent.Repo.Migrations.CreateSimulationRunRecords do
  use Ecto.Migration

  def up do
    alter table(:run_events) do
      add :sequence, :bigint
      add :round, :integer
      add :phase, :string
      add :actor_key, :string
      add :targets, {:array, :string}, null: false, default: []
      add :source_ref, :string
      add :provenance, :map, null: false, default: %{}
      add :idempotency_key, :string
    end

    create unique_index(:run_events, [:run_id, :sequence],
             where: "sequence IS NOT NULL",
             name: :run_events_sequence_uq
           )

    create unique_index(:run_events, [:run_id, :idempotency_key],
             where: "idempotency_key IS NOT NULL",
             name: :run_events_idempotency_uq
           )

    create index(:run_events, [:run_id, :round, :phase],
             where: "round IS NOT NULL",
             name: :run_events_simulation_order_idx
           )

    # A rollback removes the additive ordering columns but intentionally keeps
    # the neutral event history. Re-applying must therefore restore a safe,
    # deterministic baseline for any surviving simulation events before the
    # fail-closed constraint is installed.
    execute("""
    WITH ordered AS (
      SELECT
        id,
        row_number() OVER (
          PARTITION BY run_id
          ORDER BY inserted_at, id
        ) AS restored_sequence
      FROM run_events
      WHERE event_type LIKE 'simulation.%'
        AND sequence IS NULL
    )
    UPDATE run_events AS event
    SET
      sequence = ordered.restored_sequence,
      round = 0,
      phase = 'prepare',
      idempotency_key =
        md5(event.run_id::text || ':' || event.id::text || ':restored:1') ||
        md5(event.run_id::text || ':' || event.id::text || ':restored:2'),
      provenance = event.provenance || '{"migration_restored": true}'::jsonb
    FROM ordered
    WHERE event.id = ordered.id
    """)

    execute("""
    ALTER TABLE run_events
    ADD CONSTRAINT run_events_simulation_fields_check
    CHECK (
      event_type NOT LIKE 'simulation.%'
      OR (
        sequence IS NOT NULL
        AND sequence > 0
        AND round IS NOT NULL
        AND round >= 0
        AND phase IS NOT NULL
        AND idempotency_key IS NOT NULL
      )
    )
    """)

    create table(:simulation_run_records) do
      add :workspace_id, references(:workspaces, on_delete: :delete_all), null: false
      add :run_id, references(:runs, on_delete: :delete_all), null: false
      add :simulation_id, references(:simulations, on_delete: :restrict), null: false

      add :simulation_version_id, references(:simulation_versions, on_delete: :restrict),
        null: false

      add :context_pack_id, references(:simulation_context_packs, on_delete: :restrict),
        null: false

      add :population_model_id,
          references(:simulation_population_models, on_delete: :restrict),
          null: false

      add :simulation_script_id, references(:simulation_scripts, on_delete: :restrict),
        null: false

      add :created_by_user_id, references(:users, on_delete: :nilify_all)
      add :mode, :string, null: false, default: "quick"
      add :seed, :bigint, null: false
      add :engine_version, :string, null: false
      add :pack_hash, :string, null: false
      add :partition_count, :integer, null: false, default: 4
      add :snapshot_interval, :integer, null: false, default: 1
      add :rounds_planned, :integer, null: false
      add :current_round, :integer, null: false, default: 0
      add :last_event_sequence, :bigint, null: false, default: 0
      add :model_call_count, :integer, null: false, default: 0
      add :recovery_count, :integer, null: false, default: 0
      add :initial_state_hash, :string
      add :final_state_hash, :string
      add :result_hash, :string
      add :result_summary, :map, null: false, default: %{}
      add :failure, :map, null: false, default: %{}
      add :started_at, :utc_datetime_usec
      add :completed_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:simulation_run_records, [:run_id])
    create index(:simulation_run_records, [:workspace_id, :simulation_id, :inserted_at])
    create index(:simulation_run_records, [:simulation_id, :simulation_version_id])

    execute("""
    ALTER TABLE simulation_run_records
    ADD CONSTRAINT simulation_run_records_bounds_check
    CHECK (
      mode = 'quick'
      AND seed >= 0
      AND partition_count BETWEEN 1 AND 64
      AND snapshot_interval BETWEEN 1 AND 200
      AND rounds_planned BETWEEN 1 AND 200
      AND current_round BETWEEN 0 AND rounds_planned
      AND last_event_sequence >= 0
      AND model_call_count = 0
      AND recovery_count >= 0
      AND pack_hash ~ '^[a-f0-9]{64}$'
      AND (initial_state_hash IS NULL OR initial_state_hash ~ '^[a-f0-9]{64}$')
      AND (final_state_hash IS NULL OR final_state_hash ~ '^[a-f0-9]{64}$')
      AND (result_hash IS NULL OR result_hash ~ '^[a-f0-9]{64}$')
    )
    """)

    create table(:run_snapshots) do
      add :workspace_id, references(:workspaces, on_delete: :delete_all), null: false
      add :run_id, references(:runs, on_delete: :delete_all), null: false

      add :simulation_run_record_id,
          references(:simulation_run_records, on_delete: :delete_all),
          null: false

      add :round, :integer, null: false
      add :event_sequence, :bigint, null: false
      add :schema_version, :integer, null: false, default: 1
      add :engine_version, :string, null: false
      add :payload, :map, null: false
      add :state_hash, :string, null: false
      add :checksum, :string, null: false

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create unique_index(:run_snapshots, [:simulation_run_record_id, :round])
    create unique_index(:run_snapshots, [:run_id, :event_sequence])
    create index(:run_snapshots, [:workspace_id, :run_id, :round])

    execute("""
    ALTER TABLE run_snapshots
    ADD CONSTRAINT run_snapshots_integrity_check
    CHECK (
      round >= 0
      AND event_sequence >= 0
      AND schema_version = 1
      AND state_hash ~ '^[a-f0-9]{64}$'
      AND checksum ~ '^[a-f0-9]{64}$'
    )
    """)

    create table(:resource_transactions) do
      add :workspace_id, references(:workspaces, on_delete: :delete_all), null: false
      add :run_id, references(:runs, on_delete: :delete_all), null: false

      add :simulation_run_record_id,
          references(:simulation_run_records, on_delete: :delete_all),
          null: false

      add :sequence, :bigint, null: false
      add :round, :integer, null: false
      add :phase, :string, null: false
      add :resource_id, :string, null: false
      add :source_account, :string
      add :destination_account, :string
      add :amount, :decimal, precision: 38, scale: 8, null: false
      add :operation, :string, null: false
      add :source_ref, :string
      add :tags, {:array, :string}, null: false, default: []
      add :resulting_balances, :map, null: false, default: %{}
      add :idempotency_key, :string, null: false

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create unique_index(:resource_transactions, [:run_id, :sequence])
    create unique_index(:resource_transactions, [:run_id, :idempotency_key])
    create index(:resource_transactions, [:run_id, :round, :phase])
    create index(:resource_transactions, [:run_id, :resource_id])

    execute("""
    ALTER TABLE resource_transactions
    ADD CONSTRAINT resource_transactions_operation_check
    CHECK (
      operation IN ('mint', 'burn', 'transfer', 'reserve', 'release', 'consume', 'replenish', 'adjust')
      AND phase IN ('before_actions', 'actions', 'after_actions', 'transitions')
      AND round >= 0
      AND sequence > 0
      AND amount >= 0
      AND char_length(resource_id) BETWEEN 1 AND 120
      AND char_length(idempotency_key) BETWEEN 16 AND 160
      AND (
        (
          operation IN ('transfer', 'reserve', 'release')
          AND source_account IS NOT NULL
          AND destination_account IS NOT NULL
          AND source_account <> destination_account
        )
        OR (
          operation IN ('mint', 'replenish')
          AND source_account IS NULL
          AND destination_account IS NOT NULL
        )
        OR (
          operation IN ('burn', 'consume')
          AND source_account IS NOT NULL
          AND destination_account IS NULL
        )
        OR (
          operation = 'adjust'
          AND ((source_account IS NULL) <> (destination_account IS NULL))
        )
      )
    )
    """)

    {lineage_function, lineage_trigger} =
      immutable_trigger_sql("simulation_run_records", "simulation_run_record_lineage_immutable", [
        "workspace_id",
        "run_id",
        "simulation_id",
        "simulation_version_id",
        "context_pack_id",
        "population_model_id",
        "simulation_script_id",
        "mode",
        "seed",
        "engine_version",
        "pack_hash",
        "partition_count",
        "snapshot_interval",
        "rounds_planned"
      ])

    execute(lineage_function)
    execute(lineage_trigger)

    {snapshot_function, snapshot_trigger} =
      append_only_trigger_sql("run_snapshots", "run_snapshots_append_only")

    execute(snapshot_function)
    execute(snapshot_trigger)

    {transaction_function, transaction_trigger} =
      append_only_trigger_sql("resource_transactions", "resource_transactions_append_only")

    execute(transaction_function)
    execute(transaction_trigger)

    {scope_function, scope_trigger} = lineage_trigger_sql()
    execute(scope_function)
    execute(scope_trigger)

    {child_scope_function, snapshot_scope_trigger, transaction_scope_trigger} =
      run_child_scope_trigger_sql()

    execute(child_scope_function)
    execute(snapshot_scope_trigger)
    execute(transaction_scope_trigger)
  end

  def down do
    execute(
      "DROP TRIGGER IF EXISTS simulation_run_record_lineage_immutable_guard ON simulation_run_records"
    )

    execute("DROP FUNCTION IF EXISTS simulation_run_record_lineage_immutable()")
    execute("DROP TRIGGER IF EXISTS run_snapshots_append_only_guard ON run_snapshots")
    execute("DROP FUNCTION IF EXISTS run_snapshots_append_only()")

    execute(
      "DROP TRIGGER IF EXISTS resource_transactions_append_only_guard ON resource_transactions"
    )

    execute("DROP FUNCTION IF EXISTS resource_transactions_append_only()")
    execute("DROP TRIGGER IF EXISTS simulation_run_record_scope_guard ON simulation_run_records")
    execute("DROP FUNCTION IF EXISTS simulation_run_record_scope_valid()")
    execute("DROP TRIGGER IF EXISTS run_snapshots_scope_guard ON run_snapshots")
    execute("DROP TRIGGER IF EXISTS resource_transactions_scope_guard ON resource_transactions")
    execute("DROP FUNCTION IF EXISTS simulation_run_child_scope_valid()")

    drop table(:resource_transactions)
    drop table(:run_snapshots)
    drop table(:simulation_run_records)

    execute("ALTER TABLE run_events DROP CONSTRAINT IF EXISTS run_events_simulation_fields_check")

    drop_if_exists index(:run_events, [:run_id, :round, :phase],
                     name: :run_events_simulation_order_idx
                   )

    drop_if_exists index(:run_events, [:run_id, :idempotency_key],
                     name: :run_events_idempotency_uq
                   )

    drop_if_exists index(:run_events, [:run_id, :sequence], name: :run_events_sequence_uq)

    alter table(:run_events) do
      remove :sequence
      remove :round
      remove :phase
      remove :actor_key
      remove :targets
      remove :source_ref
      remove :provenance
      remove :idempotency_key
    end
  end

  defp immutable_trigger_sql(table, function, columns) do
    comparisons =
      columns
      |> Enum.map_join("\n        OR ", fn column ->
        "NEW.#{column} IS DISTINCT FROM OLD.#{column}"
      end)

    function_sql = """
    CREATE OR REPLACE FUNCTION #{function}()
    RETURNS trigger AS $$
    BEGIN
      IF #{comparisons} THEN
        RAISE EXCEPTION '#{table} lineage is immutable';
      END IF;
      RETURN NEW;
    END;
    $$ LANGUAGE plpgsql;
    """

    trigger_sql = """
    CREATE TRIGGER #{function}_guard
    BEFORE UPDATE ON #{table}
    FOR EACH ROW EXECUTE FUNCTION #{function}();
    """

    {function_sql, trigger_sql}
  end

  defp append_only_trigger_sql(table, function) do
    function_sql = """
    CREATE OR REPLACE FUNCTION #{function}()
    RETURNS trigger AS $$
    BEGIN
      IF TG_OP = 'UPDATE' OR pg_trigger_depth() = 1 THEN
        RAISE EXCEPTION '#{table} is append-only';
      END IF;
      RETURN OLD;
    END;
    $$ LANGUAGE plpgsql;
    """

    trigger_sql = """
    CREATE TRIGGER #{function}_guard
    BEFORE UPDATE OR DELETE ON #{table}
    FOR EACH ROW EXECUTE FUNCTION #{function}();
    """

    {function_sql, trigger_sql}
  end

  defp lineage_trigger_sql do
    function_sql = """
    CREATE OR REPLACE FUNCTION simulation_run_record_scope_valid()
    RETURNS trigger AS $$
    BEGIN
      IF NOT EXISTS (
        SELECT 1
        FROM runs r
        JOIN simulations s ON s.id = NEW.simulation_id
        JOIN simulation_versions sv ON sv.id = NEW.simulation_version_id
        JOIN simulation_context_packs cp ON cp.id = NEW.context_pack_id
        JOIN simulation_population_models pm ON pm.id = NEW.population_model_id
        JOIN simulation_scripts ss ON ss.id = NEW.simulation_script_id
        JOIN simulation_script_previews sp ON sp.simulation_script_id = ss.id
        WHERE r.id = NEW.run_id
          AND r.workspace_id = NEW.workspace_id
          AND s.workspace_id = NEW.workspace_id
          AND sv.workspace_id = NEW.workspace_id
          AND cp.workspace_id = NEW.workspace_id
          AND pm.workspace_id = NEW.workspace_id
          AND ss.workspace_id = NEW.workspace_id
          AND sv.simulation_id = s.id
          AND cp.simulation_id = s.id
          AND pm.simulation_id = s.id
          AND ss.simulation_id = s.id
          AND cp.simulation_version_id = sv.id
          AND pm.simulation_version_id = sv.id
          AND pm.context_pack_id = cp.id
          AND ss.simulation_version_id = sv.id
          AND ss.context_pack_id = cp.id
          AND ss.population_model_id = pm.id
          AND ss.status = 'ready'
          AND sp.status = 'passed'
      ) THEN
        RAISE EXCEPTION 'simulation run lineage is not exact, ready, and workspace-scoped';
      END IF;
      RETURN NEW;
    END;
    $$ LANGUAGE plpgsql;
    """

    trigger_sql = """
    CREATE TRIGGER simulation_run_record_scope_guard
    BEFORE INSERT OR UPDATE ON simulation_run_records
    FOR EACH ROW EXECUTE FUNCTION simulation_run_record_scope_valid();
    """

    {function_sql, trigger_sql}
  end

  defp run_child_scope_trigger_sql do
    function_sql = """
    CREATE OR REPLACE FUNCTION simulation_run_child_scope_valid()
    RETURNS trigger AS $$
    BEGIN
      IF NOT EXISTS (
        SELECT 1
        FROM simulation_run_records sr
        WHERE sr.id = NEW.simulation_run_record_id
          AND sr.workspace_id = NEW.workspace_id
          AND sr.run_id = NEW.run_id
          AND NEW.round BETWEEN 0 AND sr.rounds_planned
          AND (
            TG_TABLE_NAME <> 'run_snapshots'
            OR (to_jsonb(NEW)->>'engine_version') = sr.engine_version
          )
      ) THEN
        RAISE EXCEPTION 'simulation run child is not exact and workspace-scoped';
      END IF;
      RETURN NEW;
    END;
    $$ LANGUAGE plpgsql;
    """

    snapshot_trigger_sql = """
    CREATE TRIGGER run_snapshots_scope_guard
    BEFORE INSERT ON run_snapshots
    FOR EACH ROW EXECUTE FUNCTION simulation_run_child_scope_valid();
    """

    transaction_trigger_sql = """
    CREATE TRIGGER resource_transactions_scope_guard
    BEFORE INSERT ON resource_transactions
    FOR EACH ROW EXECUTE FUNCTION simulation_run_child_scope_valid();
    """

    {function_sql, snapshot_trigger_sql, transaction_trigger_sql}
  end
end
