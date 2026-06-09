defmodule HydraAgent.Simulation.Tick do
  use Ecto.Schema
  import Ecto.Changeset

  schema "simulation_ticks" do
    field :tick_number, :integer
    field :duration_us, :integer, default: 0
    field :tier_counts, :map, default: %{}
    field :llm_calls, :integer, default: 0
    field :tokens_used, :integer, default: 0
    field :cost_cents, :integer, default: 0
    field :world_delta, :map, default: %{}

    belongs_to :simulation, HydraAgent.Simulation.Simulation

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(tick, attrs) do
    tick
    |> cast(attrs, [
      :simulation_id,
      :tick_number,
      :duration_us,
      :tier_counts,
      :llm_calls,
      :tokens_used,
      :cost_cents,
      :world_delta
    ])
    |> validate_required([:simulation_id, :tick_number])
    |> validate_number(:tick_number, greater_than_or_equal_to: 0)
    |> validate_number(:duration_us, greater_than_or_equal_to: 0)
    |> validate_number(:llm_calls, greater_than_or_equal_to: 0)
    |> validate_number(:tokens_used, greater_than_or_equal_to: 0)
    |> validate_number(:cost_cents, greater_than_or_equal_to: 0)
    |> assoc_constraint(:simulation)
    |> unique_constraint([:simulation_id, :tick_number])
  end
end
