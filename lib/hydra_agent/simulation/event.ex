defmodule HydraAgent.Simulation.Event do
  use Ecto.Schema
  import Ecto.Changeset

  schema "simulation_events" do
    field :tick, :integer
    field :event_type, :string
    field :source, :string
    field :target, :string
    field :description, :string
    field :properties, :map, default: %{}
    field :stakes, :float

    belongs_to :simulation, HydraAgent.Simulation.Simulation

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(event, attrs) do
    event
    |> cast(attrs, [
      :simulation_id,
      :tick,
      :event_type,
      :source,
      :target,
      :description,
      :properties,
      :stakes
    ])
    |> validate_required([:simulation_id, :tick, :event_type])
    |> validate_number(:tick, greater_than_or_equal_to: 0)
    |> assoc_constraint(:simulation)
  end
end
