defmodule HydraAgent.Safety.Event do
  use Ecto.Schema
  import Ecto.Changeset

  @categories ~w(tool_policy approval security provider runtime)
  @severities ~w(info warning critical)

  schema "safety_events" do
    field :category, :string
    field :severity, :string, default: "info"
    field :action, :string
    field :summary, :string
    field :metadata, :map, default: %{}
    field :acknowledged_at, :utc_datetime_usec

    belongs_to :workspace, HydraAgent.Runtime.Workspace
    belongs_to :agent, HydraAgent.Runtime.AgentProfile
    belongs_to :run, HydraAgent.Runtime.Run
    belongs_to :run_step, HydraAgent.Runtime.RunStep

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(event, attrs) do
    event
    |> cast(attrs, [
      :workspace_id,
      :agent_id,
      :run_id,
      :run_step_id,
      :category,
      :severity,
      :action,
      :summary,
      :metadata,
      :acknowledged_at
    ])
    |> validate_required([:workspace_id, :category, :severity, :action, :summary])
    |> validate_inclusion(:category, @categories)
    |> validate_inclusion(:severity, @severities)
    |> assoc_constraint(:workspace)
    |> assoc_constraint(:agent)
    |> assoc_constraint(:run)
    |> assoc_constraint(:run_step)
  end
end
