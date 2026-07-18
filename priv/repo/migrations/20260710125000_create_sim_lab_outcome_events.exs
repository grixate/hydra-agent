defmodule HydraAgent.Repo.Migrations.CreateSimLabOutcomeEvents do
  use Ecto.Migration

  def change do
    create table(:sim_lab_outcome_events) do
      add :run_id, references(:sim_lab_runs, on_delete: :delete_all), null: false
      add :tick, :integer, null: false
      add :persona_id, :string, null: false
      add :action_pattern, :string, null: false
      add :action, :string, null: false
      add :probability, :float, null: false
      add :confidence, :float, null: false
      add :state_delta, :map, null: false, default: %{}
      add :metadata, :map, null: false, default: %{}

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create index(:sim_lab_outcome_events, [:run_id, :tick])
    create index(:sim_lab_outcome_events, [:run_id, :persona_id, :action])
  end
end
