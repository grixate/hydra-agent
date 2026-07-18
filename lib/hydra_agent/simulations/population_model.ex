defmodule HydraAgent.Simulations.PopulationModel do
  use Ecto.Schema
  import Ecto.Changeset

  @statuses ~w(ready partial invalid)
  @compiler_version "hydra-population/v1"

  schema "simulation_population_models" do
    field :version, :integer
    field :schema_version, :integer, default: 1
    field :compiler_version, :string, default: @compiler_version
    field :seed, :integer
    field :population_size, :integer
    field :agent_types, {:array, :map}, default: []
    field :archetypes, {:array, :map}, default: []
    field :conditional_distributions, {:array, :map}, default: []
    field :relationship_rules, {:array, :map}, default: []
    field :representative_rules, :map, default: %{}
    field :imported_agents, {:array, :map}, default: []
    field :imported_relationships, {:array, :map}, default: []
    field :import_summary, :map, default: %{}
    field :compile_summary, :map, default: %{}
    field :generation_metadata, :map, default: %{}
    field :status, :string
    field :content_hash, :string

    belongs_to :workspace, HydraAgent.Runtime.Workspace
    belongs_to :simulation, HydraAgent.Simulations.Simulation
    belongs_to :simulation_version, HydraAgent.Simulations.SimulationVersion
    belongs_to :context_pack, HydraAgent.Simulations.ContextPack
    belongs_to :created_by_user, HydraAgent.Accounts.User

    has_many :persona_projections, HydraAgent.Simulations.PersonaProjection

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  def compiler_version, do: @compiler_version

  def changeset(model, attrs) do
    model
    |> cast(attrs, [
      :workspace_id,
      :simulation_id,
      :simulation_version_id,
      :context_pack_id,
      :created_by_user_id,
      :version,
      :schema_version,
      :compiler_version,
      :seed,
      :population_size,
      :agent_types,
      :archetypes,
      :conditional_distributions,
      :relationship_rules,
      :representative_rules,
      :imported_agents,
      :imported_relationships,
      :import_summary,
      :compile_summary,
      :generation_metadata,
      :status,
      :content_hash
    ])
    |> validate_required([
      :workspace_id,
      :simulation_id,
      :simulation_version_id,
      :context_pack_id,
      :version,
      :schema_version,
      :compiler_version,
      :seed,
      :population_size,
      :agent_types,
      :archetypes,
      :conditional_distributions,
      :relationship_rules,
      :representative_rules,
      :imported_agents,
      :imported_relationships,
      :import_summary,
      :compile_summary,
      :generation_metadata,
      :status,
      :content_hash
    ])
    |> validate_number(:version, greater_than: 0)
    |> validate_number(:schema_version, equal_to: 1)
    |> validate_length(:compiler_version, min: 3, max: 80)
    |> validate_number(:seed, greater_than_or_equal_to: 0)
    |> validate_number(:population_size,
      greater_than_or_equal_to: 10,
      less_than_or_equal_to: 100_000
    )
    |> validate_inclusion(:status, @statuses)
    |> validate_format(:content_hash, ~r/^[a-f0-9]{64}$/)
    |> validate_length(:agent_types, min: 1, max: 16)
    |> validate_length(:archetypes, min: 1, max: 64)
    |> validate_length(:conditional_distributions, max: 64)
    |> validate_length(:relationship_rules, max: 16)
    |> validate_length(:imported_agents, max: 10_000)
    |> validate_length(:imported_relationships, max: 100_000)
    |> foreign_key_constraint(:workspace_id)
    |> foreign_key_constraint(:simulation_id)
    |> foreign_key_constraint(:simulation_version_id)
    |> foreign_key_constraint(:context_pack_id)
    |> foreign_key_constraint(:created_by_user_id)
    |> unique_constraint([:simulation_version_id, :version], name: :sim_pop_models_version_uq)
    |> unique_constraint([:simulation_version_id, :content_hash], name: :sim_pop_models_hash_uq)
    |> check_constraint(:version, name: :simulation_population_models_version_check)
    |> check_constraint(:population_size, name: :simulation_population_models_size_check)
    |> check_constraint(:seed, name: :simulation_population_models_seed_check)
    |> check_constraint(:status, name: :simulation_population_models_status_check)
  end

  def contract(%__MODULE__{} = model) do
    %{
      "schema_version" => model.schema_version,
      "compiler_version" => model.compiler_version,
      "seed" => model.seed,
      "population_size" => model.population_size,
      "agent_types" => model.agent_types,
      "archetypes" => model.archetypes,
      "conditional_distributions" => model.conditional_distributions,
      "relationship_rules" => model.relationship_rules,
      "representative_rules" => model.representative_rules,
      "imported_agents" => model.imported_agents,
      "imported_relationships" => model.imported_relationships,
      "import_summary" => model.import_summary,
      "compile_summary" => model.compile_summary,
      "generation_metadata" => model.generation_metadata,
      "status" => model.status,
      "content_hash" => model.content_hash
    }
  end

  def schema_payload(contract) when is_map(contract) do
    counts = get_in(contract, ["compile_summary", "archetype_counts"]) || %{}

    %{
      "hydra_population_model" => 1,
      "population_size" => contract["population_size"],
      "agent_types" => contract["agent_types"] || [],
      "archetypes" =>
        Enum.map(contract["archetypes"] || [], fn archetype ->
          archetype
          |> Map.put("count", counts[archetype["id"]] || 0)
          |> Map.put_new("goals", [])
          |> Map.put_new("initial_state", %{})
        end),
      "relationship_rules" => contract["relationship_rules"] || []
    }
  end
end
