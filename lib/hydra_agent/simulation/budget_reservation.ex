defmodule HydraAgent.Simulation.BudgetReservation do
  use Ecto.Schema
  import Ecto.Changeset

  @statuses ~w(active released exhausted canceled)
  @categories ~w(simulation)

  schema "simulation_budget_reservations" do
    field :category, :string, default: "simulation"
    field :estimated_tokens, :integer, default: 0
    field :estimated_cost_cents, :integer, default: 0
    field :reserved_cost_cents, :integer, default: 0
    field :spent_cost_cents, :integer, default: 0
    field :status, :string, default: "active"
    field :metadata, :map, default: %{}

    belongs_to :workspace, HydraAgent.Runtime.Workspace
    belongs_to :simulation, HydraAgent.Simulation.Simulation
    belongs_to :agent, HydraAgent.Runtime.AgentProfile

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(reservation, attrs) do
    reservation
    |> cast(attrs, [
      :workspace_id,
      :simulation_id,
      :agent_id,
      :category,
      :estimated_tokens,
      :estimated_cost_cents,
      :reserved_cost_cents,
      :spent_cost_cents,
      :status,
      :metadata
    ])
    |> validate_required([:workspace_id, :simulation_id, :category, :status])
    |> validate_inclusion(:category, @categories)
    |> validate_inclusion(:status, @statuses)
    |> validate_number(:estimated_tokens, greater_than_or_equal_to: 0)
    |> validate_number(:estimated_cost_cents, greater_than_or_equal_to: 0)
    |> validate_number(:reserved_cost_cents, greater_than_or_equal_to: 0)
    |> validate_number(:spent_cost_cents, greater_than_or_equal_to: 0)
    |> assoc_constraint(:workspace)
    |> assoc_constraint(:simulation)
    |> assoc_constraint(:agent)
    |> unique_constraint(:simulation_id)
  end
end
