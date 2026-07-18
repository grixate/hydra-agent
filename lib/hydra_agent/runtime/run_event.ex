defmodule HydraAgent.Runtime.RunEvent do
  use Ecto.Schema
  import Ecto.Changeset

  @event_types ~w(run.created run.started run.paused run.resumed run.canceled run.completed run.failed run.steered run.recovered step.planned step.leased step.heartbeat step.started step.blocked step.awaiting_approval step.approved step.rejected step.completed step.failed step.retrying tool.authorized tool.blocked tool.executed mcp.call.started mcp.call.completed mcp.call.failed simulation.prepared simulation.recovered simulation.round.started simulation.world_event simulation.action_batch simulation.transition simulation.observation simulation.round.completed simulation.snapshot simulation.completed simulation.canceled simulation.failed)

  schema "run_events" do
    field :event_type, :string
    field :summary, :string
    field :payload, :map, default: %{}
    field :sequence, :integer
    field :round, :integer
    field :phase, :string
    field :actor_key, :string
    field :targets, {:array, :string}, default: []
    field :source_ref, :string
    field :provenance, :map, default: %{}
    field :idempotency_key, :string

    belongs_to :workspace, HydraAgent.Runtime.Workspace
    belongs_to :run, HydraAgent.Runtime.Run
    belongs_to :run_step, HydraAgent.Runtime.RunStep
    belongs_to :agent, HydraAgent.Runtime.AgentProfile

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  def event_types, do: @event_types

  def changeset(event, attrs) do
    event
    |> cast(attrs, [
      :workspace_id,
      :run_id,
      :run_step_id,
      :agent_id,
      :event_type,
      :summary,
      :payload,
      :sequence,
      :round,
      :phase,
      :actor_key,
      :targets,
      :source_ref,
      :provenance,
      :idempotency_key
    ])
    |> validate_required([:workspace_id, :run_id, :event_type, :summary])
    |> validate_inclusion(:event_type, @event_types)
    |> validate_simulation_fields()
    |> assoc_constraint(:workspace)
    |> assoc_constraint(:run)
    |> assoc_constraint(:run_step)
    |> assoc_constraint(:agent)
    |> unique_constraint([:run_id, :sequence], name: :run_events_sequence_uq)
    |> unique_constraint([:run_id, :idempotency_key], name: :run_events_idempotency_uq)
  end

  defp validate_simulation_fields(changeset) do
    case get_field(changeset, :event_type) do
      "simulation." <> _rest ->
        changeset
        |> validate_required([:sequence, :round, :phase, :idempotency_key])
        |> validate_number(:sequence, greater_than: 0)
        |> validate_number(:round, greater_than_or_equal_to: 0)

      _event_type ->
        changeset
    end
  end
end
