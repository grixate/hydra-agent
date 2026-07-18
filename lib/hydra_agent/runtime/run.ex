defmodule HydraAgent.Runtime.Run do
  use Ecto.Schema
  import Ecto.Changeset

  alias HydraAgent.Security.WorkspaceAssociation

  @statuses ~w(planned running paused blocked awaiting_approval completed failed canceled)
  @autonomy_levels HydraAgent.Runtime.Autonomy.autonomy_levels()
  @lineage_types ~w(original retry fork delegated)

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
    field :lineage_type, :string, default: "original"
    field :lineage_reason, :string
    field :started_at, :utc_datetime_usec
    field :completed_at, :utc_datetime_usec

    belongs_to :workspace, HydraAgent.Runtime.Workspace
    belongs_to :mission, HydraAgent.Runtime.Mission
    belongs_to :supervisor_agent, HydraAgent.Runtime.AgentProfile
    belongs_to :parent_run, HydraAgent.Runtime.Run
    has_many :child_runs, HydraAgent.Runtime.Run, foreign_key: :parent_run_id
    has_many :steps, HydraAgent.Runtime.RunStep
    has_many :events, HydraAgent.Runtime.RunEvent
    has_many :turns, HydraAgent.Runtime.Turn
    has_one :simulation_run_record, HydraAgent.Simulations.SimulationRunRecord

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(run, attrs) do
    run
    |> cast(attrs, [
      :workspace_id,
      :mission_id,
      :supervisor_agent_id,
      :parent_run_id,
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
      :lineage_type,
      :lineage_reason,
      :started_at,
      :completed_at
    ])
    |> update_change(:metadata, &strip_reserved_metadata/1)
    |> validate_required([:workspace_id, :title, :goal, :status, :autonomy_level])
    |> validate_inclusion(:status, @statuses)
    |> validate_inclusion(:autonomy_level, @autonomy_levels)
    |> validate_inclusion(:lineage_type, @lineage_types)
    |> validate_number(:priority, greater_than_or_equal_to: 0, less_than_or_equal_to: 100)
    |> assoc_constraint(:workspace)
    |> assoc_constraint(:mission)
    |> assoc_constraint(:supervisor_agent)
    |> assoc_constraint(:parent_run)
    |> WorkspaceAssociation.validate(:mission_id, HydraAgent.Runtime.Mission)
    |> WorkspaceAssociation.validate(:supervisor_agent_id, HydraAgent.Runtime.AgentProfile)
    |> WorkspaceAssociation.validate(:parent_run_id, __MODULE__)
  end

  defp strip_reserved_metadata(metadata) when is_map(metadata) do
    Map.drop(metadata, ["workspace_root", :workspace_root])
  end

  defp strip_reserved_metadata(_metadata), do: %{}
end
