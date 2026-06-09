defmodule HydraAgent.Simulation.AgentProfile do
  use Ecto.Schema
  import Ecto.Changeset

  schema "simulation_agent_profiles" do
    field :agent_key, :string
    field :persona, :map, default: %{}
    field :initial_beliefs, :map, default: %{}
    field :initial_relationships, :map, default: %{}
    field :final_state, :map, default: %{}

    belongs_to :simulation, HydraAgent.Simulation.Simulation

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(profile, attrs) do
    profile
    |> cast(attrs, [
      :simulation_id,
      :agent_key,
      :persona,
      :initial_beliefs,
      :initial_relationships,
      :final_state
    ])
    |> validate_required([:simulation_id, :agent_key, :persona])
    |> assoc_constraint(:simulation)
    |> unique_constraint([:simulation_id, :agent_key])
  end
end
