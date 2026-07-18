defmodule HydraAgent.Simulations.SimulationRunRecord do
  use Ecto.Schema
  import Ecto.Changeset

  @quick_engine_version "hydra-quick/v1"
  @balanced_engine_version "hydra-balanced/v1"

  schema "simulation_run_records" do
    field :mode, :string, default: "quick"
    field :replay_kind, :string, default: "original"
    field :decision_policy, :map, default: %{}
    field :decision_manifest_hash, :string
    field :seed, :integer
    field :engine_version, :string, default: @quick_engine_version
    field :pack_hash, :string
    field :partition_count, :integer, default: 4
    field :snapshot_interval, :integer, default: 1
    field :rounds_planned, :integer
    field :current_round, :integer, default: 0
    field :last_event_sequence, :integer, default: 0
    field :model_call_count, :integer, default: 0
    field :recovery_count, :integer, default: 0
    field :initial_state_hash, :string
    field :final_state_hash, :string
    field :result_hash, :string
    field :result_summary, :map, default: %{}
    field :failure, :map, default: %{}
    field :model_route_snapshot, :map, default: %{}
    field :budget_snapshot, :map, default: %{}
    field :budget_used, :map, default: %{}
    field :fallback_count, :integer, default: 0
    field :started_at, :utc_datetime_usec
    field :completed_at, :utc_datetime_usec

    belongs_to :workspace, HydraAgent.Runtime.Workspace
    belongs_to :run, HydraAgent.Runtime.Run
    belongs_to :simulation, HydraAgent.Simulations.Simulation
    belongs_to :simulation_version, HydraAgent.Simulations.SimulationVersion
    belongs_to :context_pack, HydraAgent.Simulations.ContextPack
    belongs_to :population_model, HydraAgent.Simulations.PopulationModel
    belongs_to :simulation_script, HydraAgent.Simulations.SimulationScript
    belongs_to :model_route_plan, HydraAgent.Simulations.ModelRoutePlan
    belongs_to :budget_plan, HydraAgent.Simulations.BudgetPlan
    belongs_to :created_by_user, HydraAgent.Accounts.User
    belongs_to :replay_source, __MODULE__

    has_many :snapshots, HydraAgent.Simulations.RunSnapshot
    has_many :resource_transactions, HydraAgent.Simulations.ResourceTransaction
    has_many :budget_reservations, HydraAgent.Simulations.BudgetReservation
    has_many :decisions, HydraAgent.Simulations.RunDecision
    has_many :replays, __MODULE__, foreign_key: :replay_source_id

    timestamps(type: :utc_datetime_usec)
  end

  def engine_version, do: @quick_engine_version
  def engine_version("quick"), do: @quick_engine_version
  def engine_version("balanced"), do: @balanced_engine_version

  def changeset(record, attrs) do
    record
    |> cast(attrs, [
      :workspace_id,
      :run_id,
      :simulation_id,
      :simulation_version_id,
      :context_pack_id,
      :population_model_id,
      :simulation_script_id,
      :model_route_plan_id,
      :budget_plan_id,
      :created_by_user_id,
      :replay_source_id,
      :mode,
      :replay_kind,
      :decision_policy,
      :decision_manifest_hash,
      :seed,
      :engine_version,
      :pack_hash,
      :partition_count,
      :snapshot_interval,
      :rounds_planned,
      :current_round,
      :last_event_sequence,
      :model_call_count,
      :recovery_count,
      :initial_state_hash,
      :final_state_hash,
      :result_hash,
      :result_summary,
      :failure,
      :model_route_snapshot,
      :budget_snapshot,
      :budget_used,
      :fallback_count,
      :started_at,
      :completed_at
    ])
    |> validate_required([
      :workspace_id,
      :run_id,
      :simulation_id,
      :simulation_version_id,
      :context_pack_id,
      :population_model_id,
      :simulation_script_id,
      :model_route_plan_id,
      :budget_plan_id,
      :mode,
      :replay_kind,
      :decision_policy,
      :seed,
      :engine_version,
      :pack_hash,
      :partition_count,
      :snapshot_interval,
      :rounds_planned,
      :current_round,
      :last_event_sequence,
      :model_call_count,
      :recovery_count,
      :model_route_snapshot,
      :budget_snapshot,
      :budget_used,
      :fallback_count
    ])
    |> validate_inclusion(:mode, ~w(quick balanced))
    |> validate_inclusion(:replay_kind, ~w(original exact_replay fresh_rerun))
    |> validate_replay_source()
    |> validate_number(:seed, greater_than_or_equal_to: 0)
    |> validate_number(:partition_count, greater_than: 0, less_than_or_equal_to: 64)
    |> validate_number(:snapshot_interval, greater_than: 0, less_than_or_equal_to: 200)
    |> validate_number(:rounds_planned, greater_than: 0, less_than_or_equal_to: 200)
    |> validate_number(:current_round, greater_than_or_equal_to: 0)
    |> validate_number(:last_event_sequence, greater_than_or_equal_to: 0)
    |> validate_number(:model_call_count, greater_than_or_equal_to: 0)
    |> validate_quick_model_calls()
    |> validate_number(:recovery_count, greater_than_or_equal_to: 0)
    |> validate_number(:fallback_count, greater_than_or_equal_to: 0)
    |> validate_hash(:pack_hash)
    |> validate_optional_hash(:initial_state_hash)
    |> validate_optional_hash(:final_state_hash)
    |> validate_optional_hash(:result_hash)
    |> validate_optional_hash(:decision_manifest_hash)
    |> foreign_key_constraint(:workspace_id)
    |> foreign_key_constraint(:run_id)
    |> foreign_key_constraint(:simulation_id)
    |> foreign_key_constraint(:simulation_version_id)
    |> foreign_key_constraint(:context_pack_id)
    |> foreign_key_constraint(:population_model_id)
    |> foreign_key_constraint(:simulation_script_id)
    |> foreign_key_constraint(:model_route_plan_id)
    |> foreign_key_constraint(:budget_plan_id)
    |> foreign_key_constraint(:created_by_user_id)
    |> foreign_key_constraint(:replay_source_id)
    |> unique_constraint(:run_id)
    |> check_constraint(:mode, name: :simulation_run_records_bounds_check)
  end

  defp validate_hash(changeset, field), do: validate_format(changeset, field, ~r/^[a-f0-9]{64}$/)

  defp validate_optional_hash(changeset, field) do
    case get_field(changeset, field) do
      nil -> changeset
      _hash -> validate_hash(changeset, field)
    end
  end

  defp validate_quick_model_calls(changeset) do
    if get_field(changeset, :mode) == "quick" and get_field(changeset, :model_call_count, 0) != 0,
      do: add_error(changeset, :model_call_count, "must be zero in Quick mode"),
      else: changeset
  end

  defp validate_replay_source(changeset) do
    case {get_field(changeset, :replay_kind), get_field(changeset, :replay_source_id)} do
      {"original", nil} ->
        changeset

      {kind, source_id} when kind in ~w(exact_replay fresh_rerun) and not is_nil(source_id) ->
        changeset

      {"original", _source_id} ->
        add_error(changeset, :replay_source_id, "must be empty for an original run")

      {_kind, nil} ->
        add_error(changeset, :replay_source_id, "is required for replay runs")
    end
  end
end
