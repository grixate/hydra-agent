defmodule HydraAgent.SimLab.Schemas.CalibrationRecord do
  use Ecto.Schema
  import Ecto.Changeset

  @metrics ~w(adopt resist ignore share)

  schema "sim_lab_calibration_records" do
    field :metric, :string
    field :forecast_value, :float
    field :actual_value, :float
    field :delta, :float
    field :note, :string
    field :observed_at, :utc_datetime_usec

    belongs_to :study, HydraAgent.SimLab.Schemas.Study
    belongs_to :run, HydraAgent.SimLab.Schemas.SimulationRun

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(record, attrs) do
    record
    |> cast(attrs, [
      :study_id,
      :run_id,
      :metric,
      :forecast_value,
      :actual_value,
      :delta,
      :note,
      :observed_at
    ])
    |> validate_required([
      :study_id,
      :run_id,
      :metric,
      :forecast_value,
      :actual_value,
      :delta,
      :observed_at
    ])
    |> validate_inclusion(:metric, @metrics)
    |> validate_number(:forecast_value, greater_than_or_equal_to: 0.0, less_than_or_equal_to: 1.0)
    |> validate_number(:actual_value, greater_than_or_equal_to: 0.0, less_than_or_equal_to: 1.0)
    |> foreign_key_constraint(:study_id)
    |> foreign_key_constraint(:run_id)
  end
end
