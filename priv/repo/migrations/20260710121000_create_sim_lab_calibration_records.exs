defmodule HydraAgent.Repo.Migrations.CreateSimLabCalibrationRecords do
  use Ecto.Migration

  def change do
    create table(:sim_lab_calibration_records) do
      add :study_id, references(:sim_lab_studies, on_delete: :delete_all), null: false
      add :run_id, references(:sim_lab_runs, on_delete: :delete_all), null: false
      add :metric, :string, null: false
      add :forecast_value, :float, null: false
      add :actual_value, :float, null: false
      add :delta, :float, null: false
      add :note, :text
      add :observed_at, :utc_datetime_usec, null: false

      timestamps(type: :utc_datetime_usec)
    end

    create index(:sim_lab_calibration_records, [:run_id, :metric, :observed_at])
    create index(:sim_lab_calibration_records, [:study_id, :inserted_at])
  end
end
