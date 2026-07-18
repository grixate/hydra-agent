defmodule HydraAgent.Simulations.Simulation do
  use Ecto.Schema
  import Ecto.Changeset

  @statuses ~w(draft building needs_attention ready_to_run running analyzing ready failed canceled archived)
  @locales ~w(en ru)

  schema "simulations" do
    field :title, :string
    field :question, :string
    field :locale, :string, default: "en"
    field :status, :string, default: "draft"
    field :archived_at, :utc_datetime_usec

    belongs_to :workspace, HydraAgent.Runtime.Workspace
    belongs_to :selected_blueprint, HydraAgent.Simulations.Blueprint
    belongs_to :owner_user, HydraAgent.Accounts.User
    belongs_to :source_simulation, __MODULE__
    belongs_to :legacy_study, HydraAgent.SimLab.Schemas.Study
    belongs_to :active_version, HydraAgent.Simulations.SimulationVersion
    belongs_to :active_context_pack, HydraAgent.Simulations.ContextPack

    has_many :versions, HydraAgent.Simulations.SimulationVersion
    has_many :build_stages, HydraAgent.Simulations.BuildStage
    has_many :context_packs, HydraAgent.Simulations.ContextPack
    has_many :context_research_runs, HydraAgent.Simulations.ContextResearchRun

    timestamps(type: :utc_datetime_usec)
  end

  def statuses, do: @statuses

  def creation_changeset(simulation, attrs) do
    simulation
    |> cast(attrs, [
      :workspace_id,
      :selected_blueprint_id,
      :owner_user_id,
      :source_simulation_id,
      :legacy_study_id,
      :title,
      :question,
      :locale,
      :status
    ])
    |> validate_required([
      :workspace_id,
      :selected_blueprint_id,
      :title,
      :question,
      :locale,
      :status
    ])
    |> validate_length(:title, min: 3, max: 180)
    |> validate_length(:question, min: 10, max: 5_000)
    |> validate_inclusion(:locale, @locales)
    |> validate_inclusion(:status, @statuses -- ["archived"])
    |> foreign_key_constraint(:workspace_id)
    |> foreign_key_constraint(:selected_blueprint_id)
    |> foreign_key_constraint(:owner_user_id)
    |> foreign_key_constraint(:source_simulation_id)
    |> foreign_key_constraint(:legacy_study_id)
    |> unique_constraint(:legacy_study_id)
    |> check_constraint(:status, name: :simulations_status_check)
    |> check_constraint(:locale, name: :simulations_locale_check)
    |> check_constraint(:archived_at, name: :simulations_archive_state_check)
  end

  def activate_changeset(simulation, version) do
    simulation
    |> change(active_version_id: version.id)
    |> foreign_key_constraint(:active_version_id)
  end

  def activate_context_changeset(simulation, context_pack) do
    simulation
    |> change(active_context_pack_id: context_pack.id, status: "building")
    |> foreign_key_constraint(:active_context_pack_id)
    |> check_constraint(:status, name: :simulations_status_check)
  end

  def activate_build_changeset(simulation, version, context_pack) do
    simulation
    |> change(
      active_version_id: version.id,
      active_context_pack_id: context_pack.id,
      status: "building"
    )
    |> foreign_key_constraint(:active_version_id)
    |> foreign_key_constraint(:active_context_pack_id)
    |> check_constraint(:status, name: :simulations_status_check)
  end

  def archive_changeset(simulation, now) do
    simulation
    |> change(status: "archived", archived_at: now)
    |> check_constraint(:status, name: :simulations_status_check)
    |> check_constraint(:archived_at, name: :simulations_archive_state_check)
  end
end
