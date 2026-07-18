defmodule HydraAgent.SimLab.Schemas.Scenario do
  use Ecto.Schema
  import Ecto.Changeset

  schema "sim_lab_scenarios" do
    field :name, :string
    field :description, :string
    field :forecast_horizon, :string
    field :events, {:array, :map}, default: []
    field :available_actions, {:array, :string}, default: []
    field :success_metrics, {:array, :string}, default: []
    field :constraints, {:array, :string}, default: []
    field :metadata, :map, default: %{}

    belongs_to :study, HydraAgent.SimLab.Schemas.Study
    belongs_to :variant_of, __MODULE__
    has_many :variants, __MODULE__, foreign_key: :variant_of_id
    has_many :runs, HydraAgent.SimLab.Schemas.SimulationRun

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(scenario, attrs) do
    scenario
    |> cast(attrs, [
      :study_id,
      :name,
      :description,
      :forecast_horizon,
      :events,
      :available_actions,
      :success_metrics,
      :constraints,
      :variant_of_id,
      :metadata
    ])
    |> validate_required([:study_id, :name, :description])
    |> foreign_key_constraint(:study_id)
    |> foreign_key_constraint(:variant_of_id)
  end
end
