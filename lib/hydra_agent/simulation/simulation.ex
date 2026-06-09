defmodule HydraAgent.Simulation.Simulation do
  use Ecto.Schema
  import Ecto.Changeset

  @statuses ~w(configuring running paused completed failed canceled budget_blocked)

  schema "simulations" do
    field :title, :string
    field :goal, :string
    field :status, :string, default: "configuring"
    field :config, :map, default: %{}
    field :seed_material, :string
    field :world_snapshot, :map, default: %{}
    field :budget_plan, :map, default: %{}
    field :budget_usage, :map, default: %{}
    field :total_ticks, :integer, default: 0
    field :total_llm_calls, :integer, default: 0
    field :total_tokens_used, :integer, default: 0
    field :total_cost_cents, :integer, default: 0
    field :lease_id, :string
    field :lease_owner, :string
    field :lease_expires_at, :utc_datetime_usec
    field :last_heartbeat_at, :utc_datetime_usec
    field :recovery_count, :integer, default: 0
    field :started_at, :utc_datetime_usec
    field :completed_at, :utc_datetime_usec

    belongs_to :workspace, HydraAgent.Runtime.Workspace
    belongs_to :supervisor_agent, HydraAgent.Runtime.AgentProfile
    belongs_to :run, HydraAgent.Runtime.Run

    has_many :agent_profiles, HydraAgent.Simulation.AgentProfile
    has_many :ticks, HydraAgent.Simulation.Tick
    has_many :events, HydraAgent.Simulation.Event
    has_many :reports, HydraAgent.Simulation.Report
    has_one :budget_reservation, HydraAgent.Simulation.BudgetReservation

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(simulation, attrs) do
    simulation
    |> cast(attrs, [
      :workspace_id,
      :supervisor_agent_id,
      :run_id,
      :title,
      :goal,
      :status,
      :config,
      :seed_material,
      :world_snapshot,
      :budget_plan,
      :budget_usage,
      :total_ticks,
      :total_llm_calls,
      :total_tokens_used,
      :total_cost_cents,
      :lease_id,
      :lease_owner,
      :lease_expires_at,
      :last_heartbeat_at,
      :recovery_count,
      :started_at,
      :completed_at
    ])
    |> validate_required([:workspace_id, :title, :goal, :status])
    |> validate_inclusion(:status, @statuses)
    |> validate_number(:total_ticks, greater_than_or_equal_to: 0)
    |> validate_number(:total_llm_calls, greater_than_or_equal_to: 0)
    |> validate_number(:total_tokens_used, greater_than_or_equal_to: 0)
    |> validate_number(:total_cost_cents, greater_than_or_equal_to: 0)
    |> validate_number(:recovery_count, greater_than_or_equal_to: 0)
    |> assoc_constraint(:workspace)
    |> assoc_constraint(:supervisor_agent)
    |> assoc_constraint(:run)
  end
end
