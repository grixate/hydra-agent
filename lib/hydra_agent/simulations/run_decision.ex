defmodule HydraAgent.Simulations.RunDecision do
  use Ecto.Schema
  import Ecto.Changeset

  @sources ~w(model exact_cache policy_signature_cache representative_decision deterministic_rule exact_replay)

  schema "simulation_run_decisions" do
    field :decision_key, :string
    field :sequence, :integer
    field :round, :integer
    field :policy_id, :string
    field :agent_type, :string
    field :archetype, :string
    field :representative_agent_id, :string
    field :policy_signature, :string
    field :input_hash, :string
    field :prompt_snapshot, :map, default: %{}
    field :output, :map, default: %{}
    field :action_id, :string
    field :parameters, :map, default: %{}
    field :reason_codes, {:array, :string}, default: []
    field :short_rationale, :string, default: ""
    field :uncertainty, :decimal, default: Decimal.new(0)
    field :priority_score, :decimal, default: Decimal.new(0)
    field :score_components, :map, default: %{}
    field :source, :string
    field :provider, :string
    field :model, :string
    field :model_route_version, :string
    field :affected_agent_count, :integer
    field :reused_count, :integer, default: 0
    field :fallback, :string
    field :input_tokens, :integer, default: 0
    field :output_tokens, :integer, default: 0
    field :cost, :decimal
    field :metadata, :map, default: %{}

    belongs_to :workspace, HydraAgent.Runtime.Workspace
    belongs_to :simulation_run_record, HydraAgent.Simulations.SimulationRunRecord
    belongs_to :budget_reservation, HydraAgent.Simulations.BudgetReservation
    belongs_to :replay_source_decision, __MODULE__

    has_many :agents, HydraAgent.Simulations.RunDecisionAgent,
      foreign_key: :simulation_run_decision_id

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  def changeset(decision, attrs) do
    decision
    |> cast(attrs, [
      :workspace_id,
      :simulation_run_record_id,
      :budget_reservation_id,
      :replay_source_decision_id,
      :decision_key,
      :sequence,
      :round,
      :policy_id,
      :agent_type,
      :archetype,
      :representative_agent_id,
      :policy_signature,
      :input_hash,
      :prompt_snapshot,
      :output,
      :action_id,
      :parameters,
      :reason_codes,
      :short_rationale,
      :uncertainty,
      :priority_score,
      :score_components,
      :source,
      :provider,
      :model,
      :model_route_version,
      :affected_agent_count,
      :reused_count,
      :fallback,
      :input_tokens,
      :output_tokens,
      :cost,
      :metadata
    ])
    |> validate_required([
      :workspace_id,
      :simulation_run_record_id,
      :decision_key,
      :sequence,
      :round,
      :policy_id,
      :agent_type,
      :archetype,
      :representative_agent_id,
      :policy_signature,
      :input_hash,
      :prompt_snapshot,
      :output,
      :action_id,
      :parameters,
      :reason_codes,
      :short_rationale,
      :uncertainty,
      :priority_score,
      :score_components,
      :source,
      :affected_agent_count,
      :reused_count,
      :input_tokens,
      :output_tokens,
      :metadata
    ])
    |> validate_inclusion(:source, @sources)
    |> validate_number(:sequence, greater_than: 0)
    |> validate_number(:round, greater_than: 0)
    |> validate_number(:uncertainty, greater_than_or_equal_to: 0, less_than_or_equal_to: 1)
    |> validate_number(:priority_score,
      greater_than_or_equal_to: 0,
      less_than_or_equal_to: 1
    )
    |> validate_number(:affected_agent_count, greater_than: 0)
    |> validate_number(:reused_count, greater_than_or_equal_to: 0)
    |> validate_number(:input_tokens, greater_than_or_equal_to: 0)
    |> validate_number(:output_tokens, greater_than_or_equal_to: 0)
    |> validate_optional_nonnegative(:cost)
    |> validate_hash(:decision_key)
    |> validate_hash(:policy_signature)
    |> validate_hash(:input_hash)
    |> validate_length(:policy_id, min: 1, max: 120)
    |> validate_length(:agent_type, min: 1, max: 120)
    |> validate_length(:archetype, min: 1, max: 120)
    |> validate_length(:action_id, min: 1, max: 120)
    |> validate_length(:reason_codes, max: 12)
    |> validate_length(:short_rationale, max: 500)
    |> foreign_key_constraint(:workspace_id)
    |> foreign_key_constraint(:simulation_run_record_id)
    |> foreign_key_constraint(:budget_reservation_id)
    |> foreign_key_constraint(:replay_source_decision_id)
    |> unique_constraint([:simulation_run_record_id, :decision_key],
      name: :simulation_run_decisions_key_index
    )
    |> unique_constraint([:simulation_run_record_id, :sequence],
      name: :simulation_run_decisions_sequence_index
    )
    |> check_constraint(:source, name: :simulation_run_decisions_source_check)
    |> check_constraint(:decision_key, name: :simulation_run_decisions_bounds_check)
  end

  def sources, do: @sources

  defp validate_hash(changeset, field),
    do: validate_format(changeset, field, ~r/^[a-f0-9]{64}$/)

  defp validate_optional_nonnegative(changeset, field) do
    case get_field(changeset, field) do
      nil -> changeset
      _value -> validate_number(changeset, field, greater_than_or_equal_to: 0)
    end
  end
end
