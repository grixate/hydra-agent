defmodule HydraAgent.Repo.Migrations.CreateSimLab do
  use Ecto.Migration

  def change do
    create table(:sim_lab_studies) do
      add :workspace_id, references(:workspaces, on_delete: :delete_all), null: false
      add :title, :string, null: false
      add :question, :text, null: false
      add :domain, :string
      add :region, :string
      add :language, :string
      add :timeframe, :string
      add :target_audience, :text
      add :desired_outcomes, :map, null: false, default: %{}
      add :status, :string, null: false, default: "draft"

      timestamps(type: :utc_datetime_usec)
    end

    create index(:sim_lab_studies, [:workspace_id, :status])

    create table(:sim_lab_sources) do
      add :study_id, references(:sim_lab_studies, on_delete: :delete_all), null: false
      add :workspace_id, references(:workspaces, on_delete: :delete_all), null: false
      add :kind, :string, null: false
      add :title, :string, null: false
      add :uri, :text
      add :content_hash, :string, null: false
      add :raw_object_key, :string
      add :parsed_text, :text
      add :metadata, :map, null: false, default: %{}
      add :pii_status, :string, null: false, default: "unknown"
      add :access_policy, :map, null: false, default: %{}
      add :status, :string, null: false, default: "pending"

      timestamps(type: :utc_datetime_usec)
    end

    create index(:sim_lab_sources, [:study_id, :status])
    create index(:sim_lab_sources, [:workspace_id, :content_hash])

    create table(:sim_lab_evidence_items) do
      add :study_id, references(:sim_lab_studies, on_delete: :delete_all), null: false
      add :source_id, references(:sim_lab_sources, on_delete: :nilify_all)
      add :kind, :string, null: false, default: "claim"
      add :claim, :text, null: false
      add :normalized_claim, :text, null: false
      add :source_ref, :map, null: false, default: %{}
      add :grounding_level, :string, null: false
      add :reliability_score, :float
      add :relevance_score, :float
      add :freshness_score, :float
      add :confidence_score, :float
      add :simulation_impact, :text, null: false
      add :tags, {:array, :string}, null: false, default: []
      add :metadata, :map, null: false, default: %{}

      timestamps(type: :utc_datetime_usec)
    end

    create index(:sim_lab_evidence_items, [:study_id, :grounding_level])
    create index(:sim_lab_evidence_items, [:source_id])

    create table(:sim_lab_context_packs) do
      add :study_id, references(:sim_lab_studies, on_delete: :delete_all), null: false
      add :version, :integer, null: false, default: 1
      add :summary, :map, null: false, default: %{}
      add :source_mix, :map, null: false, default: %{}
      add :key_findings, {:array, :map}, null: false, default: []
      add :market_context, {:array, :map}, null: false, default: []
      add :behavioral_context, {:array, :map}, null: false, default: []
      add :recent_context, {:array, :map}, null: false, default: []
      add :regulatory_context, {:array, :map}, null: false, default: []
      add :risks, {:array, :map}, null: false, default: []
      add :assumptions, {:array, :map}, null: false, default: []
      add :open_questions, {:array, :map}, null: false, default: []
      add :simulation_implications, {:array, :map}, null: false, default: []
      add :confidence, :float
      add :generated_by_protocol_version, :string
      add :status, :string, null: false, default: "draft"

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:sim_lab_context_packs, [:study_id, :version])
    create index(:sim_lab_context_packs, [:study_id, :status])

    create table(:sim_lab_personas) do
      add :study_id, references(:sim_lab_studies, on_delete: :delete_all), null: false
      add :name, :string, null: false
      add :segment, :text, null: false
      add :distribution_weight, :float, null: false
      add :goals, {:array, :string}, null: false, default: []
      add :frictions, {:array, :string}, null: false, default: []
      add :triggers, {:array, :string}, null: false, default: []
      add :trust_factors, {:array, :string}, null: false, default: []
      add :decision_style, :text
      add :likely_actions, {:array, :string}, null: false, default: []
      add :behavioral_parameters, :map, null: false, default: %{}
      add :evidence_refs, {:array, :string}, null: false, default: []
      add :assumption_refs, {:array, :string}, null: false, default: []
      add :grounding_mix, :map, null: false, default: %{}
      add :confidence, :float
      add :editable_notes, :text
      add :version, :integer, null: false, default: 1
      add :status, :string, null: false, default: "active"

      timestamps(type: :utc_datetime_usec)
    end

    create index(:sim_lab_personas, [:study_id, :status])

    create table(:sim_lab_action_patterns) do
      add :study_id, references(:sim_lab_studies, on_delete: :delete_all), null: false
      add :name, :string, null: false
      add :persona_ids, {:array, :integer}, null: false, default: []
      add :condition, :text, null: false
      add :interpretation, :text, null: false
      add :motivation, :text, null: false
      add :likely_action, :string, null: false
      add :base_probability, :float, null: false
      add :blockers, {:array, :map}, null: false, default: []
      add :amplifiers, {:array, :map}, null: false, default: []
      add :state_updates, :map, null: false, default: %{}
      add :grounding_level, :string, null: false
      add :evidence_refs, {:array, :string}, null: false, default: []
      add :assumption_refs, {:array, :string}, null: false, default: []
      add :confidence, :float
      add :executable_rule, :map, null: false, default: %{}
      add :version, :integer, null: false, default: 1
      add :status, :string, null: false, default: "active"

      timestamps(type: :utc_datetime_usec)
    end

    create index(:sim_lab_action_patterns, [:study_id, :status])

    create table(:sim_lab_scenarios) do
      add :study_id, references(:sim_lab_studies, on_delete: :delete_all), null: false
      add :name, :string, null: false
      add :description, :text, null: false
      add :forecast_horizon, :string
      add :events, {:array, :map}, null: false, default: []
      add :available_actions, {:array, :string}, null: false, default: []
      add :success_metrics, {:array, :string}, null: false, default: []
      add :constraints, {:array, :string}, null: false, default: []
      add :variant_of_id, references(:sim_lab_scenarios, on_delete: :nilify_all)
      add :metadata, :map, null: false, default: %{}

      timestamps(type: :utc_datetime_usec)
    end

    create index(:sim_lab_scenarios, [:study_id])

    create table(:sim_lab_runs) do
      add :study_id, references(:sim_lab_studies, on_delete: :delete_all), null: false
      add :scenario_id, references(:sim_lab_scenarios, on_delete: :restrict), null: false
      add :context_pack_id, references(:sim_lab_context_packs, on_delete: :restrict), null: false
      add :mode, :string, null: false
      add :agent_count, :integer, null: false
      add :rounds, :integer, null: false
      add :seed, :integer, null: false
      add :status, :string, null: false, default: "queued"
      add :budget_cap_usd, :decimal
      add :actual_cost_usd, :decimal
      add :decision_counts, :map, null: false, default: %{}
      add :aggregate_metrics, :map, null: false, default: %{}
      add :confidence, :float
      add :started_at, :utc_datetime_usec
      add :completed_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create index(:sim_lab_runs, [:study_id, :status])
    create index(:sim_lab_runs, [:scenario_id, :inserted_at])

    create table(:sim_lab_snapshots) do
      add :run_id, references(:sim_lab_runs, on_delete: :delete_all), null: false
      add :tick, :integer, null: false
      add :label, :string, null: false
      add :clusters, :map, null: false, default: %{}
      add :metrics, :map, null: false, default: %{}
      add :decision_counts, :map, null: false, default: %{}
      add :cost, :map, null: false, default: %{}
      add :insight_refs, {:array, :string}, null: false, default: []

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create unique_index(:sim_lab_snapshots, [:run_id, :tick])

    create table(:sim_lab_forecast_reports) do
      add :run_id, references(:sim_lab_runs, on_delete: :delete_all), null: false
      add :study_id, references(:sim_lab_studies, on_delete: :delete_all), null: false
      add :title, :string, null: false
      add :executive_summary, :text, null: false
      add :outcome_probabilities, :map, null: false, default: %{}
      add :segment_reactions, {:array, :map}, null: false, default: []
      add :behavior_drivers, {:array, :map}, null: false, default: []
      add :resistance_drivers, {:array, :map}, null: false, default: []
      add :evidence_map, :map, null: false, default: %{}
      add :assumptions, {:array, :map}, null: false, default: []
      add :uncertainty, :map, null: false, default: %{}
      add :validation_recommendations, {:array, :string}, null: false, default: []
      add :markdown_body, :text, null: false
      add :export_object_key, :string

      timestamps(type: :utc_datetime_usec)
    end

    create index(:sim_lab_forecast_reports, [:study_id, :inserted_at])
    create unique_index(:sim_lab_forecast_reports, [:run_id])
  end
end
