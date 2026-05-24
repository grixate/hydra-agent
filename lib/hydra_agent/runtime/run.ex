defmodule HydraAgent.Runtime.Run do
  use Ecto.Schema
  import Ecto.Changeset

  @statuses ~w(planned running paused blocked awaiting_approval completed failed canceled)
  @autonomy_levels HydraAgent.Runtime.Autonomy.autonomy_levels()

  schema "runs" do
    field :title, :string
    field :goal, :string
    field :status, :string, default: "planned"
    field :autonomy_level, :string, default: "recommend"
    field :priority, :integer, default: 0
    field :budget, :map, default: %{}
    field :plan, :map, default: %{}
    field :result, :map, default: %{}
    field :runtime_state, :map, default: %{}
    field :metadata, :map, default: %{}
    field :started_at, :utc_datetime_usec
    field :completed_at, :utc_datetime_usec

    belongs_to :workspace, HydraAgent.Runtime.Workspace
    belongs_to :supervisor_agent, HydraAgent.Runtime.AgentProfile
    has_many :steps, HydraAgent.Runtime.RunStep
    has_many :events, HydraAgent.Runtime.RunEvent
    has_many :turns, HydraAgent.Runtime.Turn

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(run, attrs) do
    run
    |> cast(attrs, [
      :workspace_id,
      :supervisor_agent_id,
      :title,
      :goal,
      :status,
      :autonomy_level,
      :priority,
      :budget,
      :plan,
      :result,
      :runtime_state,
      :metadata,
      :started_at,
      :completed_at
    ])
    |> validate_required([:workspace_id, :title, :goal, :status, :autonomy_level])
    |> validate_inclusion(:status, @statuses)
    |> validate_inclusion(:autonomy_level, @autonomy_levels)
    |> validate_number(:priority, greater_than_or_equal_to: 0, less_than_or_equal_to: 100)
    |> assoc_constraint(:workspace)
    |> assoc_constraint(:supervisor_agent)
  end
end
