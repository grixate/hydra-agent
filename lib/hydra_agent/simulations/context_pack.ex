defmodule HydraAgent.Simulations.ContextPack do
  use Ecto.Schema
  import Ecto.Changeset

  @statuses ~w(ready partial failed)

  schema "simulation_context_packs" do
    field :version, :integer
    field :interpretation, :map, default: %{}
    field :scope, :map, default: %{}
    field :research_plan, {:array, :map}, default: []
    field :sources, {:array, :map}, default: []
    field :claims, {:array, :map}, default: []
    field :assumptions, {:array, :map}, default: []
    field :gaps, {:array, :map}, default: []
    field :research_metadata, :map, default: %{}
    field :historical_cutoff, :date
    field :status, :string
    field :confidence, :float
    field :content_hash, :string

    belongs_to :workspace, HydraAgent.Runtime.Workspace
    belongs_to :simulation, HydraAgent.Simulations.Simulation
    belongs_to :simulation_version, HydraAgent.Simulations.SimulationVersion
    belongs_to :created_by_user, HydraAgent.Accounts.User

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  def changeset(pack, attrs) do
    pack
    |> cast(attrs, [
      :workspace_id,
      :simulation_id,
      :simulation_version_id,
      :created_by_user_id,
      :version,
      :interpretation,
      :scope,
      :research_plan,
      :sources,
      :claims,
      :assumptions,
      :gaps,
      :research_metadata,
      :historical_cutoff,
      :status,
      :confidence,
      :content_hash
    ])
    |> validate_required([
      :workspace_id,
      :simulation_id,
      :simulation_version_id,
      :version,
      :interpretation,
      :scope,
      :research_plan,
      :sources,
      :claims,
      :assumptions,
      :gaps,
      :research_metadata,
      :status,
      :confidence,
      :content_hash
    ])
    |> validate_number(:version, greater_than: 0)
    |> validate_inclusion(:status, @statuses)
    |> validate_number(:confidence, greater_than_or_equal_to: 0.0, less_than_or_equal_to: 1.0)
    |> validate_format(:content_hash, ~r/^[a-f0-9]{64}$/)
    |> validate_length(:research_plan, max: 12)
    |> validate_length(:sources, max: 60)
    |> validate_length(:claims, max: 120)
    |> validate_length(:assumptions, max: 40)
    |> validate_length(:gaps, max: 40)
    |> foreign_key_constraint(:workspace_id)
    |> foreign_key_constraint(:simulation_id)
    |> foreign_key_constraint(:simulation_version_id)
    |> foreign_key_constraint(:created_by_user_id)
    |> unique_constraint([:simulation_version_id, :version])
    |> unique_constraint([:simulation_version_id, :content_hash])
    |> check_constraint(:version, name: :simulation_context_packs_version_check)
    |> check_constraint(:status, name: :simulation_context_packs_status_check)
    |> check_constraint(:confidence, name: :simulation_context_packs_confidence_check)
  end

  def schema_payload(%__MODULE__{} = pack) do
    schema_payload(%{
      "interpretation" => pack.interpretation,
      "claims" => pack.claims,
      "assumptions" => pack.assumptions
    })
  end

  def schema_payload(contract) when is_map(contract) do
    %{
      "hydra_context_pack" => 1,
      "question" => get_in(contract, ["interpretation", "primary_question"]),
      "facts" =>
        Enum.map(contract["claims"] || [], fn claim ->
          Map.take(claim, ["id", "statement", "grounding_class"])
        end),
      "assumptions" => Enum.map(contract["assumptions"] || [], & &1["statement"])
    }
  end
end
