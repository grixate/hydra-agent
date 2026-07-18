defmodule HydraAgent.Simulations.RunDecisionAgent do
  use Ecto.Schema
  import Ecto.Changeset

  @reuse_kinds ~w(representative signature replay)

  schema "simulation_run_decision_agents" do
    field :round, :integer
    field :agent_id, :string
    field :agent_type, :string
    field :archetype, :string
    field :reuse_kind, :string

    belongs_to :workspace, HydraAgent.Runtime.Workspace
    belongs_to :simulation_run_record, HydraAgent.Simulations.SimulationRunRecord
    belongs_to :simulation_run_decision, HydraAgent.Simulations.RunDecision

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  def changeset(mapping, attrs) do
    mapping
    |> cast(attrs, [
      :workspace_id,
      :simulation_run_record_id,
      :simulation_run_decision_id,
      :round,
      :agent_id,
      :agent_type,
      :archetype,
      :reuse_kind
    ])
    |> validate_required([
      :workspace_id,
      :simulation_run_record_id,
      :simulation_run_decision_id,
      :round,
      :agent_id,
      :agent_type,
      :archetype,
      :reuse_kind
    ])
    |> validate_inclusion(:reuse_kind, @reuse_kinds)
    |> validate_number(:round, greater_than: 0)
    |> foreign_key_constraint(:workspace_id)
    |> foreign_key_constraint(:simulation_run_record_id)
    |> foreign_key_constraint(:simulation_run_decision_id)
    |> unique_constraint([:simulation_run_record_id, :round, :agent_id],
      name: :simulation_run_decision_agents_identity_index
    )
    |> check_constraint(:reuse_kind, name: :simulation_run_decision_agents_reuse_check)
  end
end
