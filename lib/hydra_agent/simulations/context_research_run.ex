defmodule HydraAgent.Simulations.ContextResearchRun do
  use Ecto.Schema
  import Ecto.Changeset

  @providers ~w(web_search direct_sources mock)
  @statuses ~w(queued running completed failed cancelled)

  schema "simulation_context_research_runs" do
    field :provider, :string
    field :status, :string, default: "queued"
    field :input_snapshot, :map, default: %{}
    field :planned_lanes, :integer, default: 0
    field :completed_lanes, :integer, default: 0
    field :failed_lanes, :integer, default: 0
    field :failure_reason, :string
    field :started_at, :utc_datetime_usec
    field :completed_at, :utc_datetime_usec

    belongs_to :workspace, HydraAgent.Runtime.Workspace
    belongs_to :simulation, HydraAgent.Simulations.Simulation
    belongs_to :simulation_version, HydraAgent.Simulations.SimulationVersion
    belongs_to :context_pack, HydraAgent.Simulations.ContextPack

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(run, attrs) do
    run
    |> cast(attrs, [
      :workspace_id,
      :simulation_id,
      :simulation_version_id,
      :context_pack_id,
      :provider,
      :status,
      :input_snapshot,
      :planned_lanes,
      :completed_lanes,
      :failed_lanes,
      :failure_reason,
      :started_at,
      :completed_at
    ])
    |> validate_required([
      :workspace_id,
      :simulation_id,
      :simulation_version_id,
      :provider,
      :status,
      :input_snapshot,
      :planned_lanes,
      :completed_lanes,
      :failed_lanes
    ])
    |> validate_inclusion(:provider, @providers)
    |> validate_inclusion(:status, @statuses)
    |> validate_number(:planned_lanes, greater_than_or_equal_to: 0, less_than_or_equal_to: 12)
    |> validate_number(:completed_lanes, greater_than_or_equal_to: 0)
    |> validate_number(:failed_lanes, greater_than_or_equal_to: 0)
    |> validate_length(:failure_reason, max: 1_000)
    |> foreign_key_constraint(:workspace_id)
    |> foreign_key_constraint(:simulation_id)
    |> foreign_key_constraint(:simulation_version_id)
    |> foreign_key_constraint(:context_pack_id)
    |> check_constraint(:provider, name: :simulation_context_research_runs_provider_check)
    |> check_constraint(:status, name: :simulation_context_research_runs_status_check)
    |> check_constraint(:planned_lanes, name: :simulation_context_research_runs_lane_counts_check)
  end
end
