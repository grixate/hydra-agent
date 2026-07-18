defmodule HydraAgent.Simulations.ModelRoutePlan do
  use Ecto.Schema
  import Ecto.Changeset

  schema "simulation_model_route_plans" do
    field :selection, :map, default: %{}
    field :resolved_routes, :map, default: %{}
    field :capability_requirements, :map, default: %{}
    field :content_hash, :string

    belongs_to :workspace, HydraAgent.Runtime.Workspace
    belongs_to :simulation, HydraAgent.Simulations.Simulation
    belongs_to :simulation_version, HydraAgent.Simulations.SimulationVersion

    has_many :budget_plans, HydraAgent.Simulations.BudgetPlan

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  def changeset(plan, attrs) do
    plan
    |> cast(attrs, [
      :workspace_id,
      :simulation_id,
      :simulation_version_id,
      :selection,
      :resolved_routes,
      :capability_requirements,
      :content_hash
    ])
    |> validate_required([
      :workspace_id,
      :simulation_id,
      :simulation_version_id,
      :selection,
      :resolved_routes,
      :capability_requirements,
      :content_hash
    ])
    |> validate_format(:content_hash, ~r/^[a-f0-9]{64}$/)
    |> foreign_key_constraint(:workspace_id)
    |> foreign_key_constraint(:simulation_id)
    |> foreign_key_constraint(:simulation_version_id)
    |> unique_constraint([:simulation_version_id, :content_hash],
      name: :simulation_model_route_plans_content_index
    )
    |> check_constraint(:content_hash, name: :simulation_model_route_plans_hash_check)
  end
end
