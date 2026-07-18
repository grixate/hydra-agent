defmodule HydraAgent.Simulations.BuildStage do
  use Ecto.Schema
  import Ecto.Changeset

  @stages ~w(understanding_question finding_context designing_population writing_rules checking_model preparing_run)
  @statuses ~w(pending running complete partial failed superseded)

  schema "simulation_build_stages" do
    field :stage, :string
    field :ordinal, :integer
    field :status, :string, default: "pending"
    field :summary, :string
    field :warnings, {:array, :string}, default: []
    field :started_at, :utc_datetime_usec
    field :completed_at, :utc_datetime_usec

    belongs_to :workspace, HydraAgent.Runtime.Workspace
    belongs_to :simulation, HydraAgent.Simulations.Simulation
    belongs_to :simulation_version, HydraAgent.Simulations.SimulationVersion

    timestamps(type: :utc_datetime_usec)
  end

  def stages, do: @stages

  def changeset(stage, attrs) do
    stage
    |> cast(attrs, [
      :workspace_id,
      :simulation_id,
      :simulation_version_id,
      :stage,
      :ordinal,
      :status,
      :summary,
      :warnings,
      :started_at,
      :completed_at
    ])
    |> validate_required([
      :workspace_id,
      :simulation_id,
      :simulation_version_id,
      :stage,
      :ordinal,
      :status,
      :warnings
    ])
    |> validate_inclusion(:stage, @stages)
    |> validate_number(:ordinal, greater_than_or_equal_to: 1, less_than_or_equal_to: 6)
    |> validate_inclusion(:status, @statuses)
    |> validate_length(:summary, max: 500)
    |> foreign_key_constraint(:workspace_id)
    |> foreign_key_constraint(:simulation_id)
    |> foreign_key_constraint(:simulation_version_id)
    |> unique_constraint([:simulation_version_id, :stage])
    |> unique_constraint([:simulation_version_id, :ordinal])
    |> check_constraint(:stage, name: :simulation_build_stages_name_check)
    |> check_constraint(:ordinal, name: :simulation_build_stages_ordinal_check)
    |> check_constraint(:status, name: :simulation_build_stages_status_check)
  end
end
