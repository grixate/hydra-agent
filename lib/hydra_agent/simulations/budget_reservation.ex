defmodule HydraAgent.Simulations.BudgetReservation do
  use Ecto.Schema
  import Ecto.Changeset

  @kinds ~w(provider_call retrieval)
  @stages ~w(research build simulation report)
  @statuses ~w(reserved completed released rejected)

  schema "simulation_budget_reservations" do
    field :kind, :string, default: "provider_call"
    field :stage, :string
    field :status, :string, default: "reserved"
    field :provider, :string
    field :model, :string
    field :max_input_tokens, :integer, default: 0
    field :max_output_tokens, :integer, default: 0
    field :reserved_cost, :decimal
    field :actual_input_tokens, :integer
    field :actual_output_tokens, :integer
    field :actual_cost, :decimal
    field :pricing_known, :boolean, default: false
    field :idempotency_key, :string
    field :fallback, :string
    field :metadata, :map, default: %{}
    field :completed_at, :utc_datetime_usec

    belongs_to :workspace, HydraAgent.Runtime.Workspace
    belongs_to :budget_plan, HydraAgent.Simulations.BudgetPlan

    belongs_to :simulation_run_record, HydraAgent.Simulations.SimulationRunRecord

    belongs_to :usage_record, HydraAgent.Usage.Record

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(reservation, attrs) do
    reservation
    |> cast(attrs, [
      :workspace_id,
      :budget_plan_id,
      :simulation_run_record_id,
      :usage_record_id,
      :kind,
      :stage,
      :status,
      :provider,
      :model,
      :max_input_tokens,
      :max_output_tokens,
      :reserved_cost,
      :actual_input_tokens,
      :actual_output_tokens,
      :actual_cost,
      :pricing_known,
      :idempotency_key,
      :fallback,
      :metadata,
      :completed_at
    ])
    |> validate_required([
      :workspace_id,
      :budget_plan_id,
      :kind,
      :stage,
      :status,
      :max_input_tokens,
      :max_output_tokens,
      :pricing_known,
      :idempotency_key
    ])
    |> validate_inclusion(:kind, @kinds)
    |> validate_inclusion(:stage, @stages)
    |> validate_inclusion(:status, @statuses)
    |> validate_number(:max_input_tokens, greater_than_or_equal_to: 0)
    |> validate_number(:max_output_tokens, greater_than_or_equal_to: 0)
    |> validate_optional_nonnegative(:reserved_cost)
    |> validate_optional_nonnegative(:actual_input_tokens)
    |> validate_optional_nonnegative(:actual_output_tokens)
    |> validate_optional_nonnegative(:actual_cost)
    |> validate_format(:idempotency_key, ~r/^[a-f0-9]{64}$/)
    |> foreign_key_constraint(:workspace_id)
    |> foreign_key_constraint(:budget_plan_id)
    |> foreign_key_constraint(:simulation_run_record_id)
    |> foreign_key_constraint(:usage_record_id)
    |> unique_constraint([:budget_plan_id, :idempotency_key],
      name: :simulation_budget_reservations_idempotency_index
    )
    |> check_constraint(:kind, name: :simulation_budget_reservations_kind_check)
    |> check_constraint(:stage, name: :simulation_budget_reservations_stage_check)
    |> check_constraint(:status, name: :simulation_budget_reservations_status_check)
    |> check_constraint(:idempotency_key,
      name: :simulation_budget_reservations_bounds_check
    )
  end

  defp validate_optional_nonnegative(changeset, field) do
    case get_field(changeset, field) do
      nil -> changeset
      _value -> validate_number(changeset, field, greater_than_or_equal_to: 0)
    end
  end
end
