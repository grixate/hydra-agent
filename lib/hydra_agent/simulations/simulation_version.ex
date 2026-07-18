defmodule HydraAgent.Simulations.SimulationVersion do
  use Ecto.Schema
  import Ecto.Changeset

  @modes ~w(quick balanced deep)
  @budget_presets ~w(quick standard deep)

  schema "simulation_versions" do
    field :version, :integer
    field :title, :string
    field :question, :string
    field :locale, :string
    field :normalized_input, :map, default: %{}
    field :inputs, :map, default: %{}
    field :instruction_overrides, :map, default: %{}
    field :research_settings, :map, default: %{}
    field :population_size, :integer, default: 5_000
    field :execution_mode, :string, default: "quick"
    field :budget_preset, :string, default: "quick"
    field :model_routes, :map, default: %{}
    field :content_hash, :string

    belongs_to :workspace, HydraAgent.Runtime.Workspace
    belongs_to :simulation, HydraAgent.Simulations.Simulation
    belongs_to :blueprint_version, HydraAgent.Simulations.BlueprintVersion
    belongs_to :created_by_user, HydraAgent.Accounts.User

    has_many :build_stages, HydraAgent.Simulations.BuildStage
    has_many :context_packs, HydraAgent.Simulations.ContextPack
    has_many :context_research_runs, HydraAgent.Simulations.ContextResearchRun
    has_many :population_models, HydraAgent.Simulations.PopulationModel
    has_many :persona_projections, HydraAgent.Simulations.PersonaProjection

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  def changeset(version, attrs) do
    version
    |> cast(attrs, [
      :workspace_id,
      :simulation_id,
      :blueprint_version_id,
      :created_by_user_id,
      :version,
      :title,
      :question,
      :locale,
      :normalized_input,
      :inputs,
      :instruction_overrides,
      :research_settings,
      :population_size,
      :execution_mode,
      :budget_preset,
      :model_routes,
      :content_hash
    ])
    |> validate_required([
      :workspace_id,
      :simulation_id,
      :blueprint_version_id,
      :version,
      :title,
      :question,
      :locale,
      :normalized_input,
      :inputs,
      :instruction_overrides,
      :research_settings,
      :population_size,
      :execution_mode,
      :budget_preset,
      :model_routes,
      :content_hash
    ])
    |> validate_number(:version, greater_than: 0)
    |> validate_length(:title, min: 3, max: 180)
    |> validate_length(:question, min: 10, max: 5_000)
    |> validate_inclusion(:locale, ~w(en ru))
    |> validate_number(:population_size,
      greater_than_or_equal_to: 10,
      less_than_or_equal_to: 100_000
    )
    |> validate_inclusion(:execution_mode, @modes)
    |> validate_inclusion(:budget_preset, @budget_presets)
    |> validate_format(:content_hash, ~r/^[a-f0-9]{64}$/)
    |> foreign_key_constraint(:workspace_id)
    |> foreign_key_constraint(:simulation_id)
    |> foreign_key_constraint(:blueprint_version_id)
    |> foreign_key_constraint(:created_by_user_id)
    |> unique_constraint([:simulation_id, :version])
    |> unique_constraint([:simulation_id, :content_hash])
    |> check_constraint(:version, name: :simulation_versions_positive_version_check)
    |> check_constraint(:locale, name: :simulation_versions_locale_check)
    |> check_constraint(:population_size, name: :simulation_versions_population_size_check)
    |> check_constraint(:execution_mode, name: :simulation_versions_execution_mode_check)
    |> check_constraint(:budget_preset, name: :simulation_versions_budget_preset_check)
  end
end
