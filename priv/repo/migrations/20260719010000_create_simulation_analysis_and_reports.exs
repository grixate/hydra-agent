defmodule HydraAgent.Repo.Migrations.CreateSimulationAnalysisAndReports do
  use Ecto.Migration

  def up do
    create table(:simulation_analysis_packs) do
      add :workspace_id, references(:workspaces, on_delete: :delete_all), null: false
      add :run_id, references(:runs, on_delete: :delete_all), null: false
      add :simulation_id, references(:simulations, on_delete: :delete_all), null: false

      add :simulation_run_record_id,
          references(:simulation_run_records, on_delete: :delete_all),
          null: false

      add :simulation_version_id,
          references(:simulation_versions, on_delete: :restrict),
          null: false

      add :context_pack_id,
          references(:simulation_context_packs, on_delete: :restrict),
          null: false

      add :population_model_id,
          references(:simulation_population_models, on_delete: :restrict),
          null: false

      add :simulation_script_id,
          references(:simulation_scripts, on_delete: :restrict),
          null: false

      add :schema_version, :integer, null: false, default: 1
      add :protocol_version, :string, null: false, default: "hydra-analysis/v1"
      add :setup, :map, null: false, default: %{}
      add :metrics, {:array, :map}, null: false, default: []
      add :segments, {:array, :map}, null: false, default: []
      add :timeline, {:array, :map}, null: false, default: []
      add :resource_flows, {:array, :map}, null: false, default: []
      add :pivotal_events, {:array, :map}, null: false, default: []
      add :representative_traces, {:array, :map}, null: false, default: []
      add :model_decisions, {:array, :map}, null: false, default: []
      add :scenario_deltas, {:array, :map}, null: false, default: []
      add :robustness, :map, null: false, default: %{}
      add :uncertainty, :map, null: false, default: %{}
      add :grounding_refs, {:array, :map}, null: false, default: []
      add :usage, :map, null: false, default: %{}
      add :limitations, {:array, :map}, null: false, default: []
      add :reference_index, :map, null: false, default: %{}
      add :report_generation_cap, :integer, null: false, default: 8
      add :content_hash, :string, null: false
      add :generated_at, :utc_datetime_usec, null: false

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create unique_index(:simulation_analysis_packs, [:simulation_run_record_id])
    create unique_index(:simulation_analysis_packs, [:run_id])
    create index(:simulation_analysis_packs, [:simulation_id, :inserted_at])
    create index(:simulation_analysis_packs, [:workspace_id, :inserted_at])

    create constraint(:simulation_analysis_packs, :simulation_analysis_packs_bounds_check,
             check: """
             schema_version = 1 AND protocol_version = 'hydra-analysis/v1' AND
             report_generation_cap BETWEEN 1 AND 20 AND
             content_hash ~ '^[a-f0-9]{64}$'
             """
           )

    execute("""
    CREATE FUNCTION simulation_analysis_pack_scope_valid()
    RETURNS trigger AS $$
    BEGIN
      IF NOT EXISTS (
        SELECT 1
        FROM simulation_run_records run_record
        JOIN runs run ON run.id = run_record.run_id
        WHERE run_record.id = NEW.simulation_run_record_id
          AND run.status = 'completed'
          AND run_record.workspace_id = NEW.workspace_id
          AND run_record.run_id = NEW.run_id
          AND run_record.simulation_id = NEW.simulation_id
          AND run_record.simulation_version_id = NEW.simulation_version_id
          AND run_record.context_pack_id = NEW.context_pack_id
          AND run_record.population_model_id = NEW.population_model_id
          AND run_record.simulation_script_id = NEW.simulation_script_id
      ) THEN
        RAISE EXCEPTION 'Analysis Pack lineage must match a completed Simulation Run';
      END IF;
      RETURN NEW;
    END;
    $$ LANGUAGE plpgsql;
    """)

    execute("""
    CREATE TRIGGER simulation_analysis_packs_scope_guard
    BEFORE INSERT ON simulation_analysis_packs
    FOR EACH ROW EXECUTE FUNCTION simulation_analysis_pack_scope_valid();
    """)

    execute(append_only_function("simulation_analysis_packs"))
    execute(append_only_trigger("simulation_analysis_packs"))

    create table(:simulation_reports) do
      add :workspace_id, references(:workspaces, on_delete: :delete_all), null: false

      add :analysis_pack_id,
          references(:simulation_analysis_packs, on_delete: :delete_all),
          null: false

      add :simulation_run_record_id,
          references(:simulation_run_records, on_delete: :delete_all),
          null: false

      add :source_report_id, references(:simulation_reports, on_delete: :restrict)
      add :created_by_user_id, references(:users, on_delete: :nilify_all)
      add :provider_config_id, references(:provider_configs, on_delete: :restrict), null: false

      add :version, :integer, null: false
      add :status, :string, null: false, default: "queued"
      add :locale, :string, null: false
      add :audience, :string, null: false
      add :length, :string, null: false
      add :provider, :string, null: false
      add :model, :string, null: false
      add :model_route_version, :string, null: false
      add :route_snapshot, :map, null: false, default: %{}
      add :price_snapshot, :map, null: false, default: %{}
      add :currency, :string, null: false, default: "USD"
      add :pricing_known, :boolean, null: false, default: false
      add :max_input_tokens, :integer, null: false
      add :max_output_tokens, :integer, null: false
      add :reserved_cost, :decimal, precision: 18, scale: 8
      add :actual_input_tokens, :integer
      add :actual_output_tokens, :integer
      add :actual_cost, :decimal, precision: 18, scale: 8
      add :blueprint_version_hash, :string, null: false
      add :instructions_hash, :string, null: false
      add :analysis_hash, :string, null: false
      add :title, :string
      add :summary, :text
      add :sections, {:array, :map}, null: false, default: []
      add :limitations, {:array, :string}, null: false, default: []
      add :recommended_next_steps, {:array, :string}, null: false, default: []
      add :validation_status, :string, null: false, default: "pending"
      add :validation_errors, {:array, :map}, null: false, default: []
      add :content_hash, :string
      add :failure, :map, null: false, default: %{}
      add :started_at, :utc_datetime_usec
      add :completed_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:simulation_reports, [:analysis_pack_id, :version])
    create index(:simulation_reports, [:analysis_pack_id, :inserted_at])
    create index(:simulation_reports, [:simulation_run_record_id, :inserted_at])
    create index(:simulation_reports, [:source_report_id])
    create index(:simulation_reports, [:provider_config_id])

    create constraint(:simulation_reports, :simulation_reports_status_check,
             check: "status IN ('queued','running','ready','failed')"
           )

    create constraint(:simulation_reports, :simulation_reports_configuration_check,
             check: """
             version > 0 AND locale IN ('en','ru') AND
             audience IN ('general','executive','technical') AND
             length IN ('concise','standard','detailed') AND
             currency ~ '^[A-Z]{3}$' AND
             max_input_tokens BETWEEN 1 AND 100000 AND
             max_output_tokens BETWEEN 1 AND 30000 AND
             (reserved_cost IS NULL OR reserved_cost >= 0) AND
             (actual_input_tokens IS NULL OR actual_input_tokens BETWEEN 0 AND max_input_tokens) AND
             (actual_output_tokens IS NULL OR actual_output_tokens BETWEEN 0 AND max_output_tokens) AND
             (actual_cost IS NULL OR actual_cost >= 0) AND
             blueprint_version_hash ~ '^[a-f0-9]{64}$' AND
             instructions_hash ~ '^[a-f0-9]{64}$' AND
             analysis_hash ~ '^[a-f0-9]{64}$' AND
             (content_hash IS NULL OR content_hash ~ '^[a-f0-9]{64}$') AND
             validation_status IN ('pending','validated','rejected')
             """
           )

    create constraint(:simulation_reports, :simulation_reports_terminal_check,
             check: """
             (status IN ('queued','running') AND validation_status = 'pending' AND
               content_hash IS NULL AND completed_at IS NULL)
             OR
             (status = 'ready' AND validation_status = 'validated' AND
               content_hash IS NOT NULL AND title IS NOT NULL AND summary IS NOT NULL AND
               actual_input_tokens IS NOT NULL AND actual_output_tokens IS NOT NULL AND
               completed_at IS NOT NULL)
             OR
             (status = 'failed' AND validation_status = 'rejected' AND
               content_hash IS NULL AND completed_at IS NOT NULL)
             """
           )

    execute("""
    CREATE FUNCTION simulation_report_scope_valid()
    RETURNS trigger AS $$
    DECLARE report_cap integer;
    BEGIN
      SELECT analysis.report_generation_cap
      INTO report_cap
      FROM simulation_analysis_packs analysis
      WHERE analysis.id = NEW.analysis_pack_id
        AND analysis.workspace_id = NEW.workspace_id
        AND analysis.simulation_run_record_id = NEW.simulation_run_record_id
        AND analysis.content_hash = NEW.analysis_hash
      FOR UPDATE;

      IF report_cap IS NULL THEN
        RAISE EXCEPTION 'Report must belong to its Analysis Pack and Run';
      END IF;

      IF (SELECT count(*) FROM simulation_reports report
          WHERE report.analysis_pack_id = NEW.analysis_pack_id) >= report_cap THEN
        RAISE EXCEPTION 'Analysis Pack report-generation cap exhausted';
      END IF;

      IF NOT EXISTS (
        SELECT 1
        FROM provider_configs provider
        WHERE provider.id = NEW.provider_config_id
          AND provider.enabled = true
          AND (provider.workspace_id IS NULL OR provider.workspace_id = NEW.workspace_id)
      ) THEN
        RAISE EXCEPTION 'Report provider is unavailable to this workspace';
      END IF;

      IF NEW.source_report_id IS NOT NULL AND NOT EXISTS (
        SELECT 1
        FROM simulation_reports source
        WHERE source.id = NEW.source_report_id
          AND source.analysis_pack_id = NEW.analysis_pack_id
          AND source.workspace_id = NEW.workspace_id
      ) THEN
        RAISE EXCEPTION 'Report regeneration source is outside this Analysis Pack';
      END IF;

      RETURN NEW;
    END;
    $$ LANGUAGE plpgsql;
    """)

    execute("""
    CREATE TRIGGER simulation_reports_scope_guard
    BEFORE INSERT ON simulation_reports
    FOR EACH ROW EXECUTE FUNCTION simulation_report_scope_valid();
    """)

    execute("""
    CREATE FUNCTION simulation_report_lifecycle_valid()
    RETURNS trigger AS $$
    BEGIN
      IF NEW.workspace_id IS DISTINCT FROM OLD.workspace_id
         OR NEW.analysis_pack_id IS DISTINCT FROM OLD.analysis_pack_id
         OR NEW.simulation_run_record_id IS DISTINCT FROM OLD.simulation_run_record_id
         OR NEW.source_report_id IS DISTINCT FROM OLD.source_report_id
         OR NEW.created_by_user_id IS DISTINCT FROM OLD.created_by_user_id
         OR NEW.provider_config_id IS DISTINCT FROM OLD.provider_config_id
         OR NEW.version IS DISTINCT FROM OLD.version
         OR NEW.locale IS DISTINCT FROM OLD.locale
         OR NEW.audience IS DISTINCT FROM OLD.audience
         OR NEW.length IS DISTINCT FROM OLD.length
         OR NEW.provider IS DISTINCT FROM OLD.provider
         OR NEW.model IS DISTINCT FROM OLD.model
         OR NEW.model_route_version IS DISTINCT FROM OLD.model_route_version
         OR NEW.route_snapshot IS DISTINCT FROM OLD.route_snapshot
         OR NEW.price_snapshot IS DISTINCT FROM OLD.price_snapshot
         OR NEW.currency IS DISTINCT FROM OLD.currency
         OR NEW.pricing_known IS DISTINCT FROM OLD.pricing_known
         OR NEW.max_input_tokens IS DISTINCT FROM OLD.max_input_tokens
         OR NEW.max_output_tokens IS DISTINCT FROM OLD.max_output_tokens
         OR NEW.reserved_cost IS DISTINCT FROM OLD.reserved_cost
         OR NEW.blueprint_version_hash IS DISTINCT FROM OLD.blueprint_version_hash
         OR NEW.instructions_hash IS DISTINCT FROM OLD.instructions_hash
         OR NEW.analysis_hash IS DISTINCT FROM OLD.analysis_hash THEN
        RAISE EXCEPTION 'Report identity and reservation envelope are immutable';
      END IF;

      IF OLD.status IN ('ready','failed') THEN
        RAISE EXCEPTION 'Terminal Report is immutable';
      END IF;

      IF NOT (
        (OLD.status = 'queued' AND NEW.status IN ('running','failed'))
        OR (OLD.status = 'running' AND NEW.status IN ('ready','failed'))
      ) THEN
        RAISE EXCEPTION 'Invalid Report lifecycle transition';
      END IF;

      RETURN NEW;
    END;
    $$ LANGUAGE plpgsql;
    """)

    execute("""
    CREATE TRIGGER simulation_reports_lifecycle_guard
    BEFORE UPDATE ON simulation_reports
    FOR EACH ROW EXECUTE FUNCTION simulation_report_lifecycle_valid();
    """)

    execute("""
    CREATE FUNCTION simulation_reports_delete_guard()
    RETURNS trigger AS $$
    BEGIN
      IF pg_trigger_depth() = 1 THEN
        RAISE EXCEPTION 'simulation_reports history is durable';
      END IF;
      RETURN OLD;
    END;
    $$ LANGUAGE plpgsql;
    """)

    execute("""
    CREATE TRIGGER simulation_reports_delete_guard
    BEFORE DELETE ON simulation_reports
    FOR EACH ROW EXECUTE FUNCTION simulation_reports_delete_guard();
    """)
  end

  def down do
    execute("DROP TRIGGER IF EXISTS simulation_reports_delete_guard ON simulation_reports")
    execute("DROP FUNCTION IF EXISTS simulation_reports_delete_guard()")
    execute("DROP TRIGGER IF EXISTS simulation_reports_lifecycle_guard ON simulation_reports")
    execute("DROP FUNCTION IF EXISTS simulation_report_lifecycle_valid()")
    execute("DROP TRIGGER IF EXISTS simulation_reports_scope_guard ON simulation_reports")
    execute("DROP FUNCTION IF EXISTS simulation_report_scope_valid()")
    drop table(:simulation_reports)

    execute(
      "DROP TRIGGER IF EXISTS simulation_analysis_packs_append_only_guard ON simulation_analysis_packs"
    )

    execute("DROP FUNCTION IF EXISTS simulation_analysis_packs_append_only()")

    execute(
      "DROP TRIGGER IF EXISTS simulation_analysis_packs_scope_guard ON simulation_analysis_packs"
    )

    execute("DROP FUNCTION IF EXISTS simulation_analysis_pack_scope_valid()")
    drop table(:simulation_analysis_packs)
  end

  defp append_only_function(table) do
    """
    CREATE FUNCTION #{table}_append_only()
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

  defp append_only_trigger(table) do
    """
    CREATE TRIGGER #{table}_append_only_guard
    BEFORE UPDATE OR DELETE ON #{table}
    FOR EACH ROW EXECUTE FUNCTION #{table}_append_only();
    """
  end
end
