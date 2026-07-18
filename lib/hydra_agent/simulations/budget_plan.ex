defmodule HydraAgent.Simulations.BudgetPlan do
  use Ecto.Schema
  import Ecto.Changeset

  @presets ~w(quick balanced deep)
  @pricing_statuses ~w(known partial unknown)

  schema "simulation_budget_plans" do
    field :preset, :string
    field :currency, :string, default: "USD"
    field :pricing_status, :string
    field :hard_cost_cap, :decimal
    field :hard_input_token_cap, :integer
    field :hard_output_token_cap, :integer
    field :hard_model_call_cap, :integer
    field :hard_retrieval_request_cap, :integer
    field :hard_runtime_seconds, :integer
    field :max_concurrency, :integer
    field :stage_caps, :map, default: %{}
    field :price_registry_snapshot, :map, default: %{}
    field :model_route_snapshot, :map, default: %{}
    field :estimates, :map, default: %{}
    field :fallback_policy, :map, default: %{}
    field :content_hash, :string

    belongs_to :workspace, HydraAgent.Runtime.Workspace
    belongs_to :simulation, HydraAgent.Simulations.Simulation
    belongs_to :simulation_version, HydraAgent.Simulations.SimulationVersion
    belongs_to :model_route_plan, HydraAgent.Simulations.ModelRoutePlan

    has_many :reservations, HydraAgent.Simulations.BudgetReservation

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  def changeset(plan, attrs) do
    plan
    |> cast(attrs, [
      :workspace_id,
      :simulation_id,
      :simulation_version_id,
      :model_route_plan_id,
      :preset,
      :currency,
      :pricing_status,
      :hard_cost_cap,
      :hard_input_token_cap,
      :hard_output_token_cap,
      :hard_model_call_cap,
      :hard_retrieval_request_cap,
      :hard_runtime_seconds,
      :max_concurrency,
      :stage_caps,
      :price_registry_snapshot,
      :model_route_snapshot,
      :estimates,
      :fallback_policy,
      :content_hash
    ])
    |> validate_required([
      :workspace_id,
      :simulation_id,
      :simulation_version_id,
      :model_route_plan_id,
      :preset,
      :currency,
      :pricing_status,
      :hard_input_token_cap,
      :hard_output_token_cap,
      :hard_model_call_cap,
      :hard_retrieval_request_cap,
      :hard_runtime_seconds,
      :max_concurrency,
      :stage_caps,
      :price_registry_snapshot,
      :model_route_snapshot,
      :estimates,
      :fallback_policy,
      :content_hash
    ])
    |> validate_inclusion(:preset, @presets)
    |> validate_inclusion(:pricing_status, @pricing_statuses)
    |> validate_format(:currency, ~r/^[A-Z]{3}$/)
    |> validate_number(:hard_cost_cap, greater_than_or_equal_to: 0)
    |> validate_number(:hard_input_token_cap, greater_than_or_equal_to: 0)
    |> validate_number(:hard_output_token_cap, greater_than_or_equal_to: 0)
    |> validate_number(:hard_model_call_cap, greater_than_or_equal_to: 0)
    |> validate_number(:hard_retrieval_request_cap, greater_than_or_equal_to: 0)
    |> validate_number(:hard_runtime_seconds, greater_than: 0)
    |> validate_number(:max_concurrency, greater_than: 0, less_than_or_equal_to: 64)
    |> validate_format(:content_hash, ~r/^[a-f0-9]{64}$/)
    |> foreign_key_constraint(:workspace_id)
    |> foreign_key_constraint(:simulation_id)
    |> foreign_key_constraint(:simulation_version_id)
    |> foreign_key_constraint(:model_route_plan_id)
    |> unique_constraint([:simulation_version_id, :content_hash],
      name: :simulation_budget_plans_content_index
    )
    |> check_constraint(:preset, name: :simulation_budget_plans_preset_check)
    |> check_constraint(:pricing_status, name: :simulation_budget_plans_pricing_check)
    |> check_constraint(:content_hash, name: :simulation_budget_plans_bounds_check)
  end
end
