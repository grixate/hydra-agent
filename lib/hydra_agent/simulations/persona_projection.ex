defmodule HydraAgent.Simulations.PersonaProjection do
  use Ecto.Schema
  import Ecto.Changeset

  schema "simulation_persona_projections" do
    field :agent_id, :string
    field :archetype_id, :string
    field :projection, :map, default: %{}
    field :prose, :string
    field :generated_by, :string, default: "deterministic"
    field :generated_lazily, :boolean, default: true
    field :content_hash, :string

    belongs_to :workspace, HydraAgent.Runtime.Workspace
    belongs_to :simulation, HydraAgent.Simulations.Simulation
    belongs_to :simulation_version, HydraAgent.Simulations.SimulationVersion
    belongs_to :population_model, HydraAgent.Simulations.PopulationModel
    belongs_to :created_by_user, HydraAgent.Accounts.User

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  def changeset(projection, attrs) do
    projection
    |> cast(attrs, [
      :workspace_id,
      :simulation_id,
      :simulation_version_id,
      :population_model_id,
      :created_by_user_id,
      :agent_id,
      :archetype_id,
      :projection,
      :prose,
      :generated_by,
      :generated_lazily,
      :content_hash
    ])
    |> validate_required([
      :workspace_id,
      :simulation_id,
      :simulation_version_id,
      :population_model_id,
      :agent_id,
      :archetype_id,
      :projection,
      :prose,
      :generated_by,
      :generated_lazily,
      :content_hash
    ])
    |> validate_length(:agent_id, min: 3, max: 160)
    |> validate_length(:archetype_id, min: 1, max: 80)
    |> validate_length(:prose, min: 10, max: 2_000)
    |> validate_inclusion(:generated_by, ~w(deterministic model))
    |> validate_format(:content_hash, ~r/^[a-f0-9]{64}$/)
    |> foreign_key_constraint(:workspace_id)
    |> foreign_key_constraint(:simulation_id)
    |> foreign_key_constraint(:simulation_version_id)
    |> foreign_key_constraint(:population_model_id)
    |> foreign_key_constraint(:created_by_user_id)
    |> unique_constraint([:population_model_id, :agent_id], name: :sim_persona_agent_uq)
    |> check_constraint(:generated_by, name: :simulation_persona_projections_generator_check)
  end
end
