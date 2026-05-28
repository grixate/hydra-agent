defmodule HydraAgent.Runtime.RunEvent do
  use Ecto.Schema
  import Ecto.Changeset

  @event_types ~w(run.created run.started run.paused run.resumed run.canceled run.completed run.failed run.steered run.recovered step.planned step.leased step.heartbeat step.started step.blocked step.awaiting_approval step.approved step.rejected step.completed step.failed step.retrying tool.authorized tool.blocked tool.executed mcp.call.started mcp.call.completed mcp.call.failed)

  schema "run_events" do
    field :event_type, :string
    field :summary, :string
    field :payload, :map, default: %{}

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
      :payload
    ])
    |> validate_required([:workspace_id, :run_id, :event_type, :summary])
    |> validate_inclusion(:event_type, @event_types)
    |> assoc_constraint(:workspace)
    |> assoc_constraint(:run)
    |> assoc_constraint(:run_step)
    |> assoc_constraint(:agent)
  end
end
