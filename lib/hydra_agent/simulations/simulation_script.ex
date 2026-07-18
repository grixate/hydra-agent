defmodule HydraAgent.Simulations.SimulationScript do
  use Ecto.Schema
  import Ecto.Changeset

  @statuses ~w(ready blocked invalid)
  @compiler_version "hydra-script/v1"

  schema "simulation_scripts" do
    field :version, :integer
    field :schema_version, :integer, default: 1
    field :compiler_version, :string, default: @compiler_version
    field :script, :map, default: %{}
    field :validation_report, :map, default: %{}
    field :generation_metadata, :map, default: %{}
    field :status, :string
    field :content_hash, :string

    belongs_to :workspace, HydraAgent.Runtime.Workspace
    belongs_to :simulation, HydraAgent.Simulations.Simulation
    belongs_to :simulation_version, HydraAgent.Simulations.SimulationVersion
    belongs_to :context_pack, HydraAgent.Simulations.ContextPack
    belongs_to :population_model, HydraAgent.Simulations.PopulationModel
    belongs_to :created_by_user, HydraAgent.Accounts.User

    has_one :preview, HydraAgent.Simulations.ScriptPreview

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  def compiler_version, do: @compiler_version

  def changeset(script, attrs) do
    script
    |> cast(attrs, [
      :workspace_id,
      :simulation_id,
      :simulation_version_id,
      :context_pack_id,
      :population_model_id,
      :created_by_user_id,
      :version,
      :schema_version,
      :compiler_version,
      :script,
      :validation_report,
      :generation_metadata,
      :status,
      :content_hash
    ])
    |> validate_required([
      :workspace_id,
      :simulation_id,
      :simulation_version_id,
      :context_pack_id,
      :population_model_id,
      :version,
      :schema_version,
      :compiler_version,
      :script,
      :validation_report,
      :generation_metadata,
      :status,
      :content_hash
    ])
    |> validate_number(:version, greater_than: 0)
    |> validate_number(:schema_version, equal_to: 1)
    |> validate_length(:compiler_version, min: 3, max: 80)
    |> validate_inclusion(:status, @statuses)
    |> validate_format(:content_hash, ~r/^[a-f0-9]{64}$/)
    |> foreign_key_constraint(:workspace_id)
    |> foreign_key_constraint(:simulation_id)
    |> foreign_key_constraint(:simulation_version_id)
    |> foreign_key_constraint(:context_pack_id)
    |> foreign_key_constraint(:population_model_id)
    |> foreign_key_constraint(:created_by_user_id)
    |> unique_constraint([:simulation_version_id, :version], name: :sim_scripts_version_uq)
    |> unique_constraint([:simulation_version_id, :content_hash], name: :sim_scripts_hash_uq)
    |> check_constraint(:version, name: :simulation_scripts_version_check)
    |> check_constraint(:status, name: :simulation_scripts_status_check)
  end

  def contract(%__MODULE__{} = record) do
    %{
      "schema_version" => record.schema_version,
      "compiler_version" => record.compiler_version,
      "script" => record.script,
      "validation_report" => record.validation_report,
      "generation_metadata" => record.generation_metadata,
      "status" => record.status,
      "content_hash" => record.content_hash
    }
  end

  def schema_payload(%{"script" => script}) when is_map(script), do: script
  def schema_payload(script) when is_map(script), do: script
end
