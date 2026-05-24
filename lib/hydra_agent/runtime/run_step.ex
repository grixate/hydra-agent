defmodule HydraAgent.Runtime.RunStep do
  use Ecto.Schema
  import Ecto.Changeset

  @statuses ~w(planned running blocked awaiting_approval completed failed canceled skipped)
  @side_effect_classes HydraAgent.Runtime.Autonomy.side_effect_classes()

  schema "run_steps" do
    field :index, :integer
    field :title, :string
    field :status, :string, default: "planned"
    field :tool_name, :string
    field :side_effect_class, :string, default: "read_only"
    field :input, :map, default: %{}
    field :output, :map, default: %{}
    field :approval, :map, default: %{}
    field :error, :map, default: %{}
    field :attempt_count, :integer, default: 0
    field :lease_owner, :string
    field :lease_expires_at, :utc_datetime_usec
    field :heartbeat_at, :utc_datetime_usec
    field :started_at, :utc_datetime_usec
    field :completed_at, :utc_datetime_usec

    belongs_to :run, HydraAgent.Runtime.Run
    belongs_to :assigned_agent, HydraAgent.Runtime.AgentProfile
    has_many :events, HydraAgent.Runtime.RunEvent

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(step, attrs) do
    step
    |> cast(attrs, [
      :run_id,
      :assigned_agent_id,
      :index,
      :title,
      :status,
      :tool_name,
      :side_effect_class,
      :input,
      :output,
      :approval,
      :error,
      :attempt_count,
      :lease_owner,
      :lease_expires_at,
      :heartbeat_at,
      :started_at,
      :completed_at
    ])
    |> validate_required([:run_id, :index, :title, :status, :side_effect_class])
    |> validate_number(:index, greater_than_or_equal_to: 0)
    |> validate_number(:attempt_count, greater_than_or_equal_to: 0)
    |> validate_inclusion(:status, @statuses)
    |> validate_inclusion(:side_effect_class, @side_effect_classes)
    |> assoc_constraint(:run)
    |> assoc_constraint(:assigned_agent)
  end
end
