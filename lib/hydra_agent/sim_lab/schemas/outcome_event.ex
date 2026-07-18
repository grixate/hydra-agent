defmodule HydraAgent.SimLab.Schemas.OutcomeEvent do
  use Ecto.Schema
  import Ecto.Changeset

  schema "sim_lab_outcome_events" do
    field :tick, :integer
    field :persona_id, :string
    field :action_pattern, :string
    field :action, :string
    field :probability, :float
    field :confidence, :float
    field :state_delta, :map, default: %{}
    field :metadata, :map, default: %{}

    belongs_to :run, HydraAgent.SimLab.Schemas.SimulationRun

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  def changeset(event, attrs) do
    event
    |> cast(attrs, [
      :run_id,
      :tick,
      :persona_id,
      :action_pattern,
      :action,
      :probability,
      :confidence,
      :state_delta,
      :metadata
    ])
    |> validate_required([
      :run_id,
      :tick,
      :persona_id,
      :action_pattern,
      :action,
      :probability,
      :confidence
    ])
    |> validate_number(:tick, greater_than: 0)
    |> validate_number(:probability, greater_than_or_equal_to: 0.0, less_than_or_equal_to: 1.0)
    |> validate_number(:confidence, greater_than_or_equal_to: 0.0, less_than_or_equal_to: 1.0)
    |> foreign_key_constraint(:run_id)
  end
end
