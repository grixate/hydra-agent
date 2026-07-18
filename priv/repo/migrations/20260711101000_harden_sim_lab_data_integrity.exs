defmodule HydraAgent.Repo.Migrations.HardenSimLabDataIntegrity do
  use Ecto.Migration

  def change do
    create constraint(:sim_lab_personas, :sim_lab_personas_distribution_weight_range,
             check: "distribution_weight > 0 AND distribution_weight <= 1"
           )

    create constraint(:sim_lab_personas, :sim_lab_personas_confidence_range,
             check: "confidence IS NULL OR (confidence >= 0 AND confidence <= 1)"
           )

    create constraint(:sim_lab_action_patterns, :sim_lab_action_patterns_probability_range,
             check: "base_probability >= 0 AND base_probability <= 1"
           )

    create constraint(:sim_lab_action_patterns, :sim_lab_action_patterns_confidence_range,
             check: "confidence IS NULL OR (confidence >= 0 AND confidence <= 1)"
           )

    create constraint(:sim_lab_context_packs, :sim_lab_context_packs_confidence_range,
             check: "confidence IS NULL OR (confidence >= 0 AND confidence <= 1)"
           )

    create constraint(:sim_lab_runs, :sim_lab_runs_positive_size,
             check: "agent_count > 0 AND rounds > 0"
           )

    create constraint(:sim_lab_runs, :sim_lab_runs_confidence_range,
             check: "confidence IS NULL OR (confidence >= 0 AND confidence <= 1)"
           )

    create constraint(:sim_lab_outcome_events, :sim_lab_outcome_events_probability_range,
             check: "probability >= 0 AND probability <= 1"
           )

    create constraint(:sim_lab_outcome_events, :sim_lab_outcome_events_confidence_range,
             check: "confidence >= 0 AND confidence <= 1"
           )

    create constraint(:sim_lab_calibration_records, :sim_lab_calibration_values_range,
             check:
               "forecast_value >= 0 AND forecast_value <= 1 AND actual_value >= 0 AND actual_value <= 1"
           )

    create table(:sim_lab_action_pattern_personas) do
      add :action_pattern_id,
          references(:sim_lab_action_patterns, on_delete: :delete_all),
          null: false

      add :persona_id, references(:sim_lab_personas, on_delete: :delete_all), null: false

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create unique_index(:sim_lab_action_pattern_personas, [:action_pattern_id, :persona_id])
    create index(:sim_lab_action_pattern_personas, [:persona_id])

    execute(
      """
      INSERT INTO sim_lab_action_pattern_personas
        (action_pattern_id, persona_id, inserted_at)
      SELECT pattern.id, persona.id, NOW()
      FROM sim_lab_action_patterns AS pattern
      CROSS JOIN LATERAL unnest(pattern.persona_ids) AS linked_persona_id
      JOIN sim_lab_personas AS persona
        ON persona.id = linked_persona_id
       AND persona.study_id = pattern.study_id
      ON CONFLICT DO NOTHING
      """,
      "DELETE FROM sim_lab_action_pattern_personas"
    )
  end
end
