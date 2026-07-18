defmodule HydraAgent.Repo.Migrations.CreateSimulationBudgetGovernor do
  use Ecto.Migration

  def up do
    create table(:simulation_price_entries) do
      add :workspace_id, references(:workspaces, on_delete: :delete_all)
      add :provider, :string, null: false
      add :model, :string, null: false
      add :currency, :string, null: false, default: "USD"
      add :input_per_million, :decimal, precision: 18, scale: 8
      add :cached_input_per_million, :decimal, precision: 18, scale: 8
      add :output_per_million, :decimal, precision: 18, scale: 8
      add :request_minimum, :decimal, precision: 18, scale: 8
      add :effective_from, :utc_datetime_usec, null: false
      add :operator_override, :boolean, null: false, default: false
      add :metadata, :map, null: false, default: %{}

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create unique_index(
             :simulation_price_entries,
             [:provider, :model, :effective_from],
             where: "workspace_id IS NULL",
             name: :simulation_price_entries_global_identity_index
           )

    create unique_index(
             :simulation_price_entries,
             [:workspace_id, :provider, :model, :effective_from],
             where: "workspace_id IS NOT NULL",
             name: :simulation_price_entries_workspace_identity_index
           )

    create index(:simulation_price_entries, [:workspace_id, :provider, :model, :effective_from],
             name: :simulation_price_entries_lookup_index
           )

    create constraint(:simulation_price_entries, :simulation_price_entries_currency_check,
             check: "currency ~ '^[A-Z]{3}$'"
           )

    create constraint(:simulation_price_entries, :simulation_price_entries_nonnegative_check,
             check: """
             (input_per_million IS NULL OR input_per_million >= 0) AND
             (cached_input_per_million IS NULL OR cached_input_per_million >= 0) AND
             (output_per_million IS NULL OR output_per_million >= 0) AND
             (request_minimum IS NULL OR request_minimum >= 0)
             """
           )

    create table(:simulation_model_route_plans) do
      add :workspace_id, references(:workspaces, on_delete: :delete_all), null: false
      add :simulation_id, references(:simulations, on_delete: :delete_all), null: false

      add :simulation_version_id, references(:simulation_versions, on_delete: :delete_all),
        null: false

      add :selection, :map, null: false, default: %{}
      add :resolved_routes, :map, null: false, default: %{}
      add :capability_requirements, :map, null: false, default: %{}
      add :content_hash, :string, null: false

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create unique_index(:simulation_model_route_plans, [:simulation_version_id, :content_hash],
             name: :simulation_model_route_plans_content_index
           )

    create index(:simulation_model_route_plans, [:workspace_id, :simulation_id])

    create constraint(:simulation_model_route_plans, :simulation_model_route_plans_hash_check,
             check: "content_hash ~ '^[a-f0-9]{64}$'"
           )

    create table(:simulation_budget_plans) do
      add :workspace_id, references(:workspaces, on_delete: :delete_all), null: false
      add :simulation_id, references(:simulations, on_delete: :delete_all), null: false

      add :simulation_version_id, references(:simulation_versions, on_delete: :delete_all),
        null: false

      add :model_route_plan_id,
          references(:simulation_model_route_plans, on_delete: :delete_all),
          null: false

      add :preset, :string, null: false
      add :currency, :string, null: false, default: "USD"
      add :pricing_status, :string, null: false
      add :hard_cost_cap, :decimal, precision: 18, scale: 8
      add :hard_input_token_cap, :bigint, null: false
      add :hard_output_token_cap, :bigint, null: false
      add :hard_model_call_cap, :integer, null: false
      add :hard_retrieval_request_cap, :integer, null: false
      add :hard_runtime_seconds, :integer, null: false
      add :max_concurrency, :integer, null: false
      add :stage_caps, :map, null: false, default: %{}
      add :price_registry_snapshot, :map, null: false, default: %{}
      add :model_route_snapshot, :map, null: false, default: %{}
      add :estimates, :map, null: false, default: %{}
      add :fallback_policy, :map, null: false, default: %{}
      add :content_hash, :string, null: false

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create unique_index(:simulation_budget_plans, [:simulation_version_id, :content_hash],
             name: :simulation_budget_plans_content_index
           )

    create index(:simulation_budget_plans, [:workspace_id, :simulation_id])
    create index(:simulation_budget_plans, [:model_route_plan_id])

    create constraint(:simulation_budget_plans, :simulation_budget_plans_preset_check,
             check: "preset IN ('quick','balanced','deep')"
           )

    create constraint(:simulation_budget_plans, :simulation_budget_plans_pricing_check,
             check: "pricing_status IN ('known','partial','unknown')"
           )

    create constraint(:simulation_budget_plans, :simulation_budget_plans_bounds_check,
             check: """
             currency ~ '^[A-Z]{3}$' AND
             (hard_cost_cap IS NULL OR hard_cost_cap >= 0) AND
             hard_input_token_cap >= 0 AND
             hard_output_token_cap >= 0 AND
             hard_model_call_cap >= 0 AND
             hard_retrieval_request_cap >= 0 AND
             hard_runtime_seconds > 0 AND
             max_concurrency > 0 AND max_concurrency <= 64 AND
             content_hash ~ '^[a-f0-9]{64}$'
             """
           )

    create table(:simulation_budget_reservations) do
      add :workspace_id, references(:workspaces, on_delete: :delete_all), null: false

      add :budget_plan_id, references(:simulation_budget_plans, on_delete: :delete_all),
        null: false

      add :simulation_run_record_id,
          references(:simulation_run_records, on_delete: :delete_all)

      add :usage_record_id, references(:usage_records, on_delete: :nilify_all)
      add :kind, :string, null: false, default: "provider_call"
      add :stage, :string, null: false
      add :status, :string, null: false, default: "reserved"
      add :provider, :string
      add :model, :string
      add :max_input_tokens, :integer, null: false, default: 0
      add :max_output_tokens, :integer, null: false, default: 0
      add :reserved_cost, :decimal, precision: 18, scale: 8
      add :actual_input_tokens, :integer
      add :actual_output_tokens, :integer
      add :actual_cost, :decimal, precision: 18, scale: 8
      add :pricing_known, :boolean, null: false, default: false
      add :idempotency_key, :string, null: false
      add :fallback, :string
      add :metadata, :map, null: false, default: %{}
      add :completed_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:simulation_budget_reservations, [:budget_plan_id, :idempotency_key],
             name: :simulation_budget_reservations_idempotency_index
           )

    create index(:simulation_budget_reservations, [:budget_plan_id, :stage, :status],
             name: :sim_budget_reservations_plan_stage_status_index
           )

    create index(:simulation_budget_reservations, [:simulation_run_record_id])

    create constraint(
             :simulation_budget_reservations,
             :simulation_budget_reservations_kind_check,
             check: "kind IN ('provider_call','retrieval')"
           )

    create constraint(
             :simulation_budget_reservations,
             :simulation_budget_reservations_stage_check,
             check: "stage IN ('research','build','simulation','report')"
           )

    create constraint(
             :simulation_budget_reservations,
             :simulation_budget_reservations_status_check,
             check: "status IN ('reserved','completed','released','rejected')"
           )

    create constraint(
             :simulation_budget_reservations,
             :simulation_budget_reservations_bounds_check,
             check: """
             max_input_tokens >= 0 AND max_output_tokens >= 0 AND
             (reserved_cost IS NULL OR reserved_cost >= 0) AND
             (actual_input_tokens IS NULL OR actual_input_tokens >= 0) AND
             (actual_output_tokens IS NULL OR actual_output_tokens >= 0) AND
             (actual_cost IS NULL OR actual_cost >= 0) AND
             idempotency_key ~ '^[a-f0-9]{64}$'
             """
           )

    alter table(:simulation_run_records) do
      add :model_route_plan_id, references(:simulation_model_route_plans, on_delete: :restrict)
      add :budget_plan_id, references(:simulation_budget_plans, on_delete: :restrict)
      add :model_route_snapshot, :map, null: false, default: %{}
      add :budget_snapshot, :map, null: false, default: %{}
      add :budget_used, :map, null: false, default: %{}
      add :fallback_count, :integer, null: false, default: 0
    end

    create index(:simulation_run_records, [:model_route_plan_id])
    create index(:simulation_run_records, [:budget_plan_id])

    execute("""
    INSERT INTO simulation_model_route_plans
      (workspace_id, simulation_id, simulation_version_id, selection, resolved_routes,
       capability_requirements, content_hash, inserted_at)
    SELECT
      workspace_id,
      simulation_id,
      id,
      model_routes,
      jsonb_build_object(
        'build', jsonb_build_object('selection', COALESCE(model_routes->>'build', 'automatic'), 'status', 'unavailable'),
        'simulation', jsonb_build_object('selection', 'none', 'status', 'disabled'),
        'report', jsonb_build_object('selection', COALESCE(model_routes->>'report', 'automatic'), 'status', 'unavailable')
      ),
      jsonb_build_object(
        'build', jsonb_build_array('structured_generation'),
        'simulation', jsonb_build_array('structured_generation'),
        'report', jsonb_build_array('structured_generation')
      ),
      md5('route-plan:' || id::text) || md5('route-plan:v1:' || id::text),
      inserted_at
    FROM simulation_versions;
    """)

    execute("""
    INSERT INTO simulation_budget_plans
      (workspace_id, simulation_id, simulation_version_id, model_route_plan_id, preset,
       currency, pricing_status, hard_cost_cap, hard_input_token_cap,
       hard_output_token_cap, hard_model_call_cap, hard_retrieval_request_cap,
       hard_runtime_seconds, max_concurrency, stage_caps, price_registry_snapshot,
       model_route_snapshot, estimates, fallback_policy, content_hash, inserted_at)
    SELECT
      sv.workspace_id,
      sv.simulation_id,
      sv.id,
      mrp.id,
      CASE sv.budget_preset WHEN 'deep' THEN 'deep' WHEN 'standard' THEN 'balanced' ELSE 'quick' END,
      'USD',
      'unknown',
      NULL,
      CASE sv.budget_preset WHEN 'deep' THEN 600000 WHEN 'standard' THEN 300000 ELSE 200000 END,
      CASE sv.budget_preset WHEN 'deep' THEN 120000 WHEN 'standard' THEN 60000 ELSE 40000 END,
      CASE sv.budget_preset WHEN 'deep' THEN 200 WHEN 'standard' THEN 88 ELSE 5 END,
      CASE sv.budget_preset WHEN 'deep' THEN 20 WHEN 'standard' THEN 12 ELSE 8 END,
      CASE sv.budget_preset WHEN 'deep' THEN 1800 ELSE 900 END,
      CASE sv.budget_preset WHEN 'deep' THEN 8 WHEN 'standard' THEN 8 ELSE 4 END,
      CASE sv.budget_preset
        WHEN 'deep' THEN jsonb_build_object(
          'research', jsonb_build_object('calls', 20, 'input_tokens', 60000, 'output_tokens', 10000),
          'build', jsonb_build_object('calls', 10, 'input_tokens', 140000, 'output_tokens', 30000),
          'simulation', jsonb_build_object('calls', 186, 'input_tokens', 320000, 'output_tokens', 70000),
          'report', jsonb_build_object('calls', 4, 'input_tokens', 80000, 'output_tokens', 10000)
        )
        WHEN 'standard' THEN jsonb_build_object(
          'research', jsonb_build_object('calls', 12, 'input_tokens', 40000, 'output_tokens', 5000),
          'build', jsonb_build_object('calls', 6, 'input_tokens', 80000, 'output_tokens', 15000),
          'simulation', jsonb_build_object('calls', 80, 'input_tokens', 140000, 'output_tokens', 30000),
          'report', jsonb_build_object('calls', 2, 'input_tokens', 40000, 'output_tokens', 10000)
        )
        ELSE jsonb_build_object(
          'research', jsonb_build_object('calls', 8, 'input_tokens', 30000, 'output_tokens', 4000),
          'build', jsonb_build_object('calls', 4, 'input_tokens', 70000, 'output_tokens', 14000),
          'simulation', jsonb_build_object('calls', 0, 'input_tokens', 0, 'output_tokens', 0),
          'report', jsonb_build_object('calls', 1, 'input_tokens', 30000, 'output_tokens', 8000)
        )
      END,
      jsonb_build_object('captured_at', sv.inserted_at, 'entries', jsonb_build_object()),
      mrp.resolved_routes,
      jsonb_build_object('cost_status', 'unknown', 'currency', 'USD'),
      jsonb_build_object('order', jsonb_build_array(
        'deterministic_rule', 'exact_cache', 'policy_signature_cache',
        'representative_decision', 'cheaper_or_local_model', 'conservative_action',
        'stop_model_lane'
      )),
      md5('budget-plan:' || sv.id::text) || md5('budget-plan:v1:' || sv.id::text),
      sv.inserted_at
    FROM simulation_versions sv
    JOIN simulation_model_route_plans mrp ON mrp.simulation_version_id = sv.id;
    """)

    execute("""
    UPDATE simulation_run_records srr
    SET model_route_plan_id = mrp.id,
        budget_plan_id = bp.id,
        model_route_snapshot = mrp.resolved_routes,
        budget_snapshot = jsonb_build_object(
          'preset', bp.preset,
          'currency', bp.currency,
          'pricing_status', bp.pricing_status,
          'hard_cost_cap', bp.hard_cost_cap,
          'hard_input_token_cap', bp.hard_input_token_cap,
          'hard_output_token_cap', bp.hard_output_token_cap,
          'hard_model_call_cap', bp.hard_model_call_cap,
          'hard_retrieval_request_cap', bp.hard_retrieval_request_cap,
          'hard_runtime_seconds', bp.hard_runtime_seconds,
          'max_concurrency', bp.max_concurrency,
          'stage_caps', bp.stage_caps,
          'price_registry_snapshot', bp.price_registry_snapshot,
          'content_hash', bp.content_hash
        )
    FROM simulation_model_route_plans mrp
    JOIN simulation_budget_plans bp ON bp.model_route_plan_id = mrp.id
    WHERE srr.simulation_version_id = mrp.simulation_version_id;
    """)

    alter table(:simulation_run_records) do
      modify :model_route_plan_id, :bigint, null: false
      modify :budget_plan_id, :bigint, null: false
    end

    create constraint(:simulation_run_records, :simulation_run_records_budget_bounds_check,
             check: "fallback_count >= 0"
           )

    execute("""
    CREATE FUNCTION validate_simulation_configuration_scope()
    RETURNS trigger AS $$
    DECLARE
      version_workspace_id bigint;
      version_simulation_id bigint;
      route_workspace_id bigint;
      route_simulation_id bigint;
      route_version_id bigint;
    BEGIN
      SELECT workspace_id, simulation_id
      INTO version_workspace_id, version_simulation_id
      FROM simulation_versions
      WHERE id = NEW.simulation_version_id;

      IF version_workspace_id IS NULL
         OR version_workspace_id IS DISTINCT FROM NEW.workspace_id
         OR version_simulation_id IS DISTINCT FROM NEW.simulation_id THEN
        RAISE EXCEPTION 'simulation configuration scope does not match its Simulation Version';
      END IF;

      IF TG_TABLE_NAME = 'simulation_budget_plans' THEN
        SELECT workspace_id, simulation_id, simulation_version_id
        INTO route_workspace_id, route_simulation_id, route_version_id
        FROM simulation_model_route_plans
        WHERE id = NEW.model_route_plan_id;

        IF route_workspace_id IS NULL
           OR route_workspace_id IS DISTINCT FROM NEW.workspace_id
           OR route_simulation_id IS DISTINCT FROM NEW.simulation_id
           OR route_version_id IS DISTINCT FROM NEW.simulation_version_id THEN
          RAISE EXCEPTION 'Budget Plan scope does not match its Model Route Plan';
        END IF;
      END IF;

      RETURN NEW;
    END;
    $$ LANGUAGE plpgsql;
    """)

    execute("""
    CREATE TRIGGER simulation_model_route_plans_scope_integrity
    BEFORE INSERT ON simulation_model_route_plans
    FOR EACH ROW EXECUTE FUNCTION validate_simulation_configuration_scope();
    """)

    execute("""
    CREATE TRIGGER simulation_budget_plans_scope_integrity
    BEFORE INSERT ON simulation_budget_plans
    FOR EACH ROW EXECUTE FUNCTION validate_simulation_configuration_scope();
    """)

    execute("""
    CREATE FUNCTION prevent_simulation_configuration_update()
    RETURNS trigger AS $$
    BEGIN
      RAISE EXCEPTION 'simulation configuration records are immutable';
    END;
    $$ LANGUAGE plpgsql;
    """)

    execute("""
    CREATE TRIGGER simulation_price_entries_immutable
    BEFORE UPDATE ON simulation_price_entries
    FOR EACH ROW EXECUTE FUNCTION prevent_simulation_configuration_update();
    """)

    execute("""
    CREATE TRIGGER simulation_model_route_plans_immutable
    BEFORE UPDATE ON simulation_model_route_plans
    FOR EACH ROW EXECUTE FUNCTION prevent_simulation_configuration_update();
    """)

    execute("""
    CREATE TRIGGER simulation_budget_plans_immutable
    BEFORE UPDATE ON simulation_budget_plans
    FOR EACH ROW EXECUTE FUNCTION prevent_simulation_configuration_update();
    """)

    execute("""
    CREATE FUNCTION validate_simulation_budget_reservation_scope()
    RETURNS trigger AS $$
    DECLARE
      plan_workspace_id bigint;
      run_workspace_id bigint;
      run_budget_plan_id bigint;
    BEGIN
      SELECT workspace_id INTO plan_workspace_id
      FROM simulation_budget_plans
      WHERE id = NEW.budget_plan_id;

      IF plan_workspace_id IS NULL OR plan_workspace_id IS DISTINCT FROM NEW.workspace_id THEN
        RAISE EXCEPTION 'budget reservation scope does not match its Budget Plan';
      END IF;

      IF NEW.simulation_run_record_id IS NOT NULL THEN
        SELECT workspace_id, budget_plan_id
        INTO run_workspace_id, run_budget_plan_id
        FROM simulation_run_records
        WHERE id = NEW.simulation_run_record_id;

        IF run_workspace_id IS NULL
           OR run_workspace_id IS DISTINCT FROM NEW.workspace_id
           OR run_budget_plan_id IS DISTINCT FROM NEW.budget_plan_id THEN
          RAISE EXCEPTION 'budget reservation scope does not match its Run';
        END IF;
      END IF;

      IF TG_OP = 'UPDATE' AND (
        OLD.workspace_id IS DISTINCT FROM NEW.workspace_id OR
        OLD.budget_plan_id IS DISTINCT FROM NEW.budget_plan_id OR
        OLD.simulation_run_record_id IS DISTINCT FROM NEW.simulation_run_record_id OR
        OLD.kind IS DISTINCT FROM NEW.kind OR
        OLD.stage IS DISTINCT FROM NEW.stage OR
        OLD.provider IS DISTINCT FROM NEW.provider OR
        OLD.model IS DISTINCT FROM NEW.model OR
        OLD.max_input_tokens IS DISTINCT FROM NEW.max_input_tokens OR
        OLD.max_output_tokens IS DISTINCT FROM NEW.max_output_tokens OR
        OLD.reserved_cost IS DISTINCT FROM NEW.reserved_cost OR
        OLD.pricing_known IS DISTINCT FROM NEW.pricing_known OR
        OLD.idempotency_key IS DISTINCT FROM NEW.idempotency_key
      ) THEN
        RAISE EXCEPTION 'budget reservation identity is immutable';
      END IF;

      RETURN NEW;
    END;
    $$ LANGUAGE plpgsql;
    """)

    execute("""
    CREATE TRIGGER simulation_budget_reservations_scope_integrity
    BEFORE INSERT OR UPDATE ON simulation_budget_reservations
    FOR EACH ROW EXECUTE FUNCTION validate_simulation_budget_reservation_scope();
    """)
  end

  def down do
    execute(
      "DROP TRIGGER IF EXISTS simulation_budget_reservations_scope_integrity ON simulation_budget_reservations"
    )

    execute("DROP FUNCTION IF EXISTS validate_simulation_budget_reservation_scope()")
    execute("DROP TRIGGER IF EXISTS simulation_budget_plans_immutable ON simulation_budget_plans")

    execute(
      "DROP TRIGGER IF EXISTS simulation_model_route_plans_immutable ON simulation_model_route_plans"
    )

    execute(
      "DROP TRIGGER IF EXISTS simulation_price_entries_immutable ON simulation_price_entries"
    )

    execute("DROP FUNCTION IF EXISTS prevent_simulation_configuration_update()")

    execute(
      "DROP TRIGGER IF EXISTS simulation_budget_plans_scope_integrity ON simulation_budget_plans"
    )

    execute(
      "DROP TRIGGER IF EXISTS simulation_model_route_plans_scope_integrity ON simulation_model_route_plans"
    )

    execute("DROP FUNCTION IF EXISTS validate_simulation_configuration_scope()")

    alter table(:simulation_run_records) do
      remove :fallback_count
      remove :budget_used
      remove :budget_snapshot
      remove :model_route_snapshot
      remove :budget_plan_id
      remove :model_route_plan_id
    end

    drop table(:simulation_budget_reservations)
    drop table(:simulation_budget_plans)
    drop table(:simulation_model_route_plans)
    drop table(:simulation_price_entries)
  end
end
