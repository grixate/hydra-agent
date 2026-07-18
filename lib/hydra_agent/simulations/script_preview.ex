defmodule HydraAgent.Simulations.ScriptPreview do
  use Ecto.Schema
  import Ecto.Changeset

  @statuses ~w(passed failed)

  schema "simulation_script_previews" do
    field :status, :string
    field :rounds_requested, :integer, default: 2
    field :rounds_completed, :integer, default: 0
    field :agent_count, :integer, default: 0
    field :seed, :integer
    field :summary, :map, default: %{}
    field :errors, {:array, :map}, default: []
    field :result_hash, :string

    belongs_to :workspace, HydraAgent.Runtime.Workspace
    belongs_to :simulation, HydraAgent.Simulations.Simulation
    belongs_to :simulation_version, HydraAgent.Simulations.SimulationVersion
    belongs_to :population_model, HydraAgent.Simulations.PopulationModel
    belongs_to :simulation_script, HydraAgent.Simulations.SimulationScript

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  def changeset(preview, attrs) do
    preview
    |> cast(attrs, [
      :workspace_id,
      :simulation_id,
      :simulation_version_id,
      :population_model_id,
      :simulation_script_id,
      :status,
      :rounds_requested,
      :rounds_completed,
      :agent_count,
      :seed,
      :summary,
      :errors,
      :result_hash
    ])
    |> validate_required([
      :workspace_id,
      :simulation_id,
      :simulation_version_id,
      :population_model_id,
      :simulation_script_id,
      :status,
      :rounds_requested,
      :rounds_completed,
      :agent_count,
      :seed,
      :summary,
      :errors,
      :result_hash
    ])
    |> validate_inclusion(:status, @statuses)
    |> validate_number(:rounds_requested, greater_than_or_equal_to: 1, less_than_or_equal_to: 2)
    |> validate_number(:rounds_completed, greater_than_or_equal_to: 0, less_than_or_equal_to: 2)
    |> validate_number(:agent_count, greater_than_or_equal_to: 0, less_than_or_equal_to: 12)
    |> validate_number(:seed, greater_than_or_equal_to: 0)
    |> validate_length(:errors, max: 100)
    |> validate_format(:result_hash, ~r/^[a-f0-9]{64}$/)
    |> foreign_key_constraint(:workspace_id)
    |> foreign_key_constraint(:simulation_id)
    |> foreign_key_constraint(:simulation_version_id)
    |> foreign_key_constraint(:population_model_id)
    |> foreign_key_constraint(:simulation_script_id)
    |> unique_constraint(:simulation_script_id, name: :sim_script_previews_script_uq)
    |> check_constraint(:status, name: :simulation_script_previews_status_check)
    |> check_constraint(:rounds_requested, name: :simulation_script_previews_bounds_check)
  end
end
