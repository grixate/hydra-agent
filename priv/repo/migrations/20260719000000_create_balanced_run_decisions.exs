defmodule HydraAgent.Repo.Migrations.CreateBalancedRunDecisions do
  use Ecto.Migration

  def up do
    execute(
      "ALTER TABLE simulation_run_records DROP CONSTRAINT simulation_run_records_bounds_check"
    )

    alter table(:simulation_run_records) do
      add :replay_kind, :string, null: false, default: "original"

      add :replay_source_id,
          references(:simulation_run_records, on_delete: :restrict)

      add :decision_policy, :map, null: false, default: %{}
      add :decision_manifest_hash, :string
    end

    create index(:simulation_run_records, [:replay_source_id])

    execute("""
    ALTER TABLE simulation_run_records
    ADD CONSTRAINT simulation_run_records_bounds_check
    CHECK (
      mode IN ('quick','balanced')
      AND replay_kind IN ('original','exact_replay','fresh_rerun')
      AND seed >= 0
      AND partition_count BETWEEN 1 AND 64
      AND snapshot_interval BETWEEN 1 AND 200
      AND rounds_planned BETWEEN 1 AND 200
      AND current_round BETWEEN 0 AND rounds_planned
      AND last_event_sequence >= 0
      AND model_call_count >= 0
      AND (mode <> 'quick' OR model_call_count = 0)
      AND recovery_count >= 0
      AND pack_hash ~ '^[a-f0-9]{64}$'
      AND (initial_state_hash IS NULL OR initial_state_hash ~ '^[a-f0-9]{64}$')
      AND (final_state_hash IS NULL OR final_state_hash ~ '^[a-f0-9]{64}$')
      AND (result_hash IS NULL OR result_hash ~ '^[a-f0-9]{64}$')
      AND (decision_manifest_hash IS NULL OR decision_manifest_hash ~ '^[a-f0-9]{64}$')
      AND (
        (replay_kind = 'original' AND replay_source_id IS NULL)
        OR (replay_kind IN ('exact_replay','fresh_rerun') AND replay_source_id IS NOT NULL)
      )
      AND (replay_source_id IS NULL OR replay_source_id <> id)
    )
    """)

    execute("""
    CREATE OR REPLACE FUNCTION simulation_run_record_lineage_immutable()
    RETURNS trigger AS $$
    BEGIN
      IF NEW.workspace_id IS DISTINCT FROM OLD.workspace_id
         OR NEW.run_id IS DISTINCT FROM OLD.run_id
         OR NEW.simulation_id IS DISTINCT FROM OLD.simulation_id
         OR NEW.simulation_version_id IS DISTINCT FROM OLD.simulation_version_id
         OR NEW.context_pack_id IS DISTINCT FROM OLD.context_pack_id
         OR NEW.population_model_id IS DISTINCT FROM OLD.population_model_id
         OR NEW.simulation_script_id IS DISTINCT FROM OLD.simulation_script_id
         OR NEW.model_route_plan_id IS DISTINCT FROM OLD.model_route_plan_id
         OR NEW.budget_plan_id IS DISTINCT FROM OLD.budget_plan_id
         OR NEW.mode IS DISTINCT FROM OLD.mode
         OR NEW.replay_kind IS DISTINCT FROM OLD.replay_kind
         OR NEW.replay_source_id IS DISTINCT FROM OLD.replay_source_id
         OR NEW.decision_policy IS DISTINCT FROM OLD.decision_policy
         OR NEW.seed IS DISTINCT FROM OLD.seed
         OR NEW.engine_version IS DISTINCT FROM OLD.engine_version
         OR NEW.pack_hash IS DISTINCT FROM OLD.pack_hash
         OR NEW.partition_count IS DISTINCT FROM OLD.partition_count
         OR NEW.snapshot_interval IS DISTINCT FROM OLD.snapshot_interval
         OR NEW.rounds_planned IS DISTINCT FROM OLD.rounds_planned THEN
        RAISE EXCEPTION 'simulation_run_records lineage is immutable';
      END IF;
      RETURN NEW;
    END;
    $$ LANGUAGE plpgsql;
    """)

    execute("""
    CREATE FUNCTION simulation_replay_source_valid()
    RETURNS trigger AS $$
    BEGIN
      IF NEW.replay_kind = 'original' THEN
        RETURN NEW;
      END IF;

      IF NOT EXISTS (
        SELECT 1
        FROM simulation_run_records source
        JOIN runs source_run ON source_run.id = source.run_id
        WHERE source.id = NEW.replay_source_id
          AND source_run.status = 'completed'
          AND source.workspace_id = NEW.workspace_id
          AND source.simulation_id = NEW.simulation_id
          AND (
            NEW.replay_kind = 'fresh_rerun'
            OR (
              source.simulation_version_id = NEW.simulation_version_id
              AND source.context_pack_id = NEW.context_pack_id
              AND source.population_model_id = NEW.population_model_id
              AND source.simulation_script_id = NEW.simulation_script_id
              AND source.model_route_plan_id = NEW.model_route_plan_id
              AND source.budget_plan_id = NEW.budget_plan_id
              AND source.mode = NEW.mode
              AND source.seed = NEW.seed
              AND source.engine_version = NEW.engine_version
              AND source.pack_hash = NEW.pack_hash
            )
          )
      ) THEN
        RAISE EXCEPTION 'simulation replay source is not compatible and completed';
      END IF;

      RETURN NEW;
    END;
    $$ LANGUAGE plpgsql;
    """)

    execute("""
    CREATE TRIGGER simulation_replay_source_guard
    BEFORE INSERT OR UPDATE ON simulation_run_records
    FOR EACH ROW EXECUTE FUNCTION simulation_replay_source_valid();
    """)

    create table(:simulation_run_decisions) do
      add :workspace_id, references(:workspaces, on_delete: :delete_all), null: false

      add :simulation_run_record_id,
          references(:simulation_run_records, on_delete: :delete_all),
          null: false

      add :budget_reservation_id,
          references(:simulation_budget_reservations, on_delete: :restrict)

      add :replay_source_decision_id,
          references(:simulation_run_decisions, on_delete: :restrict)

      add :decision_key, :string, null: false
      add :sequence, :bigint, null: false
      add :round, :integer, null: false
      add :policy_id, :string, null: false
      add :agent_type, :string, null: false
      add :archetype, :string, null: false
      add :representative_agent_id, :string, null: false
      add :policy_signature, :string, null: false
      add :input_hash, :string, null: false
      add :prompt_snapshot, :map, null: false, default: %{}
      add :output, :map, null: false, default: %{}
      add :action_id, :string, null: false
      add :parameters, :map, null: false, default: %{}
      add :reason_codes, {:array, :string}, null: false, default: []
      add :short_rationale, :text, null: false, default: ""
      add :uncertainty, :decimal, precision: 7, scale: 6, null: false, default: 0
      add :priority_score, :decimal, precision: 9, scale: 6, null: false, default: 0
      add :score_components, :map, null: false, default: %{}
      add :source, :string, null: false
      add :provider, :string
      add :model, :string
      add :model_route_version, :string
      add :affected_agent_count, :integer, null: false
      add :reused_count, :integer, null: false, default: 0
      add :fallback, :string
      add :input_tokens, :integer, null: false, default: 0
      add :output_tokens, :integer, null: false, default: 0
      add :cost, :decimal, precision: 18, scale: 8
      add :metadata, :map, null: false, default: %{}

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create unique_index(:simulation_run_decisions, [:simulation_run_record_id, :decision_key],
             name: :simulation_run_decisions_key_index
           )

    create unique_index(:simulation_run_decisions, [:simulation_run_record_id, :sequence],
             name: :simulation_run_decisions_sequence_index
           )

    create index(:simulation_run_decisions, [
             :simulation_run_record_id,
             :round,
             :policy_signature
           ])

    create index(:simulation_run_decisions, [:replay_source_decision_id])

    create constraint(:simulation_run_decisions, :simulation_run_decisions_source_check,
             check:
               "source IN ('model','exact_cache','policy_signature_cache','representative_decision','deterministic_rule','exact_replay')"
           )

    create constraint(:simulation_run_decisions, :simulation_run_decisions_bounds_check,
             check: """
             decision_key ~ '^[a-f0-9]{64}$' AND sequence > 0 AND round > 0 AND
             policy_signature ~ '^[a-f0-9]{64}$' AND input_hash ~ '^[a-f0-9]{64}$' AND
             uncertainty >= 0 AND uncertainty <= 1 AND
             priority_score >= 0 AND priority_score <= 1 AND
             affected_agent_count > 0 AND reused_count >= 0 AND
             reused_count <= affected_agent_count AND
             input_tokens >= 0 AND output_tokens >= 0 AND
             (cost IS NULL OR cost >= 0) AND
             char_length(representative_agent_id) BETWEEN 1 AND 160
             """
           )

    create table(:simulation_run_decision_agents) do
      add :workspace_id, references(:workspaces, on_delete: :delete_all), null: false

      add :simulation_run_record_id,
          references(:simulation_run_records, on_delete: :delete_all),
          null: false

      add :simulation_run_decision_id,
          references(:simulation_run_decisions, on_delete: :delete_all),
          null: false

      add :round, :integer, null: false
      add :agent_id, :string, null: false
      add :agent_type, :string, null: false
      add :archetype, :string, null: false
      add :reuse_kind, :string, null: false

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create unique_index(
             :simulation_run_decision_agents,
             [:simulation_run_record_id, :round, :agent_id],
             name: :simulation_run_decision_agents_identity_index
           )

    create index(:simulation_run_decision_agents, [:simulation_run_decision_id])
    create index(:simulation_run_decision_agents, [:simulation_run_record_id, :agent_id])

    create constraint(
             :simulation_run_decision_agents,
             :simulation_run_decision_agents_reuse_check,
             check:
               "reuse_kind IN ('representative','signature','replay') AND round > 0 AND char_length(agent_id) BETWEEN 1 AND 160"
           )

    execute("""
    CREATE FUNCTION simulation_run_decision_scope_valid()
    RETURNS trigger AS $$
    BEGIN
      IF NOT EXISTS (
        SELECT 1
        FROM simulation_run_records run_record
        WHERE run_record.id = NEW.simulation_run_record_id
          AND run_record.workspace_id = NEW.workspace_id
          AND NEW.round BETWEEN 1 AND run_record.rounds_planned
      ) THEN
        RAISE EXCEPTION 'Run Decision is not scoped to its Run';
      END IF;

      IF NEW.budget_reservation_id IS NOT NULL AND NOT EXISTS (
        SELECT 1
        FROM simulation_budget_reservations reservation
        JOIN simulation_run_records run_record
          ON run_record.id = NEW.simulation_run_record_id
        WHERE reservation.id = NEW.budget_reservation_id
          AND reservation.workspace_id = NEW.workspace_id
          AND reservation.budget_plan_id = run_record.budget_plan_id
          AND reservation.simulation_run_record_id = run_record.id
      ) THEN
        RAISE EXCEPTION 'Run Decision reservation is not scoped to its Run';
      END IF;

      IF NEW.replay_source_decision_id IS NOT NULL AND NOT EXISTS (
        SELECT 1
        FROM simulation_run_decisions source
        JOIN simulation_run_records current_run
          ON current_run.id = NEW.simulation_run_record_id
        WHERE source.id = NEW.replay_source_decision_id
          AND source.workspace_id = NEW.workspace_id
          AND (
            source.simulation_run_record_id = current_run.id
            OR source.simulation_run_record_id = current_run.replay_source_id
          )
      ) THEN
        RAISE EXCEPTION 'Run Decision replay source is not compatible';
      END IF;

      RETURN NEW;
    END;
    $$ LANGUAGE plpgsql;
    """)

    execute("""
    CREATE TRIGGER simulation_run_decisions_scope_guard
    BEFORE INSERT ON simulation_run_decisions
    FOR EACH ROW EXECUTE FUNCTION simulation_run_decision_scope_valid();
    """)

    execute("""
    CREATE FUNCTION simulation_run_decision_agent_scope_valid()
    RETURNS trigger AS $$
    BEGIN
      IF NOT EXISTS (
        SELECT 1
        FROM simulation_run_decisions decision
        WHERE decision.id = NEW.simulation_run_decision_id
          AND decision.workspace_id = NEW.workspace_id
          AND decision.simulation_run_record_id = NEW.simulation_run_record_id
          AND decision.round = NEW.round
          AND decision.agent_type = NEW.agent_type
          AND decision.archetype = NEW.archetype
      ) THEN
        RAISE EXCEPTION 'Run Decision agent mapping is not scoped to its decision';
      END IF;
      RETURN NEW;
    END;
    $$ LANGUAGE plpgsql;
    """)

    execute("""
    CREATE TRIGGER simulation_run_decision_agents_scope_guard
    BEFORE INSERT ON simulation_run_decision_agents
    FOR EACH ROW EXECUTE FUNCTION simulation_run_decision_agent_scope_valid();
    """)

    execute(
      append_only_function("simulation_run_decisions", "simulation_run_decisions_append_only")
    )

    execute(
      append_only_trigger("simulation_run_decisions", "simulation_run_decisions_append_only")
    )

    execute(
      append_only_function(
        "simulation_run_decision_agents",
        "simulation_run_decision_agents_append_only"
      )
    )

    execute(
      append_only_trigger(
        "simulation_run_decision_agents",
        "simulation_run_decision_agents_append_only"
      )
    )
  end

  def down do
    execute(
      "DROP TRIGGER IF EXISTS simulation_run_decision_agents_append_only_guard ON simulation_run_decision_agents"
    )

    execute("DROP FUNCTION IF EXISTS simulation_run_decision_agents_append_only()")

    execute(
      "DROP TRIGGER IF EXISTS simulation_run_decisions_append_only_guard ON simulation_run_decisions"
    )

    execute("DROP FUNCTION IF EXISTS simulation_run_decisions_append_only()")

    execute(
      "DROP TRIGGER IF EXISTS simulation_run_decision_agents_scope_guard ON simulation_run_decision_agents"
    )

    execute("DROP FUNCTION IF EXISTS simulation_run_decision_agent_scope_valid()")

    execute(
      "DROP TRIGGER IF EXISTS simulation_run_decisions_scope_guard ON simulation_run_decisions"
    )

    execute("DROP FUNCTION IF EXISTS simulation_run_decision_scope_valid()")
    drop table(:simulation_run_decision_agents)
    drop table(:simulation_run_decisions)
    execute("DROP TRIGGER IF EXISTS simulation_replay_source_guard ON simulation_run_records")
    execute("DROP FUNCTION IF EXISTS simulation_replay_source_valid()")

    execute("""
    CREATE OR REPLACE FUNCTION simulation_run_record_lineage_immutable()
    RETURNS trigger AS $$
    BEGIN
      IF NEW.workspace_id IS DISTINCT FROM OLD.workspace_id
         OR NEW.run_id IS DISTINCT FROM OLD.run_id
         OR NEW.simulation_id IS DISTINCT FROM OLD.simulation_id
         OR NEW.simulation_version_id IS DISTINCT FROM OLD.simulation_version_id
         OR NEW.context_pack_id IS DISTINCT FROM OLD.context_pack_id
         OR NEW.population_model_id IS DISTINCT FROM OLD.population_model_id
         OR NEW.simulation_script_id IS DISTINCT FROM OLD.simulation_script_id
         OR NEW.mode IS DISTINCT FROM OLD.mode
         OR NEW.seed IS DISTINCT FROM OLD.seed
         OR NEW.engine_version IS DISTINCT FROM OLD.engine_version
         OR NEW.pack_hash IS DISTINCT FROM OLD.pack_hash
         OR NEW.partition_count IS DISTINCT FROM OLD.partition_count
         OR NEW.snapshot_interval IS DISTINCT FROM OLD.snapshot_interval
         OR NEW.rounds_planned IS DISTINCT FROM OLD.rounds_planned THEN
        RAISE EXCEPTION 'simulation_run_records lineage is immutable';
      END IF;
      RETURN NEW;
    END;
    $$ LANGUAGE plpgsql;
    """)

    execute(
      "ALTER TABLE simulation_run_records DROP CONSTRAINT simulation_run_records_bounds_check"
    )

    alter table(:simulation_run_records) do
      remove :decision_manifest_hash
      remove :decision_policy
      remove :replay_source_id
      remove :replay_kind
    end

    execute("""
    ALTER TABLE simulation_run_records
    ADD CONSTRAINT simulation_run_records_bounds_check
    CHECK (
      mode = 'quick' AND seed >= 0 AND partition_count BETWEEN 1 AND 64 AND
      snapshot_interval BETWEEN 1 AND 200 AND rounds_planned BETWEEN 1 AND 200 AND
      current_round BETWEEN 0 AND rounds_planned AND last_event_sequence >= 0 AND
      model_call_count = 0 AND recovery_count >= 0 AND
      pack_hash ~ '^[a-f0-9]{64}$' AND
      (initial_state_hash IS NULL OR initial_state_hash ~ '^[a-f0-9]{64}$') AND
      (final_state_hash IS NULL OR final_state_hash ~ '^[a-f0-9]{64}$') AND
      (result_hash IS NULL OR result_hash ~ '^[a-f0-9]{64}$')
    )
    """)
  end

  defp append_only_function(table, function) do
    """
    CREATE FUNCTION #{function}()
    RETURNS trigger AS $$
    BEGIN
      IF TG_OP = 'UPDATE' OR pg_trigger_depth() = 1 THEN
        RAISE EXCEPTION '#{table} is append-only';
      END IF;
      RETURN OLD;
    END;
    $$ LANGUAGE plpgsql;
    """
  end

  defp append_only_trigger(table, function) do
    """
    CREATE TRIGGER #{function}_guard
    BEFORE UPDATE OR DELETE ON #{table}
    FOR EACH ROW EXECUTE FUNCTION #{function}();
    """
  end
end
