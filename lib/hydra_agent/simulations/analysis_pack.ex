defmodule HydraAgent.Simulations.AnalysisPack do
  use Ecto.Schema
  import Ecto.Changeset

  schema "simulation_analysis_packs" do
    field :schema_version, :integer, default: 1
    field :protocol_version, :string, default: "hydra-analysis/v1"
    field :setup, :map, default: %{}
    field :metrics, {:array, :map}, default: []
    field :segments, {:array, :map}, default: []
    field :timeline, {:array, :map}, default: []
    field :resource_flows, {:array, :map}, default: []
    field :pivotal_events, {:array, :map}, default: []
    field :representative_traces, {:array, :map}, default: []
    field :model_decisions, {:array, :map}, default: []
    field :scenario_deltas, {:array, :map}, default: []
    field :robustness, :map, default: %{}
    field :uncertainty, :map, default: %{}
    field :grounding_refs, {:array, :map}, default: []
    field :usage, :map, default: %{}
    field :limitations, {:array, :map}, default: []
    field :reference_index, :map, default: %{}
    field :report_generation_cap, :integer, default: 8
    field :content_hash, :string
    field :generated_at, :utc_datetime_usec

    belongs_to :workspace, HydraAgent.Runtime.Workspace
    belongs_to :run, HydraAgent.Runtime.Run
    belongs_to :simulation, HydraAgent.Simulations.Simulation
    belongs_to :simulation_run_record, HydraAgent.Simulations.SimulationRunRecord
    belongs_to :simulation_version, HydraAgent.Simulations.SimulationVersion
    belongs_to :context_pack, HydraAgent.Simulations.ContextPack
    belongs_to :population_model, HydraAgent.Simulations.PopulationModel
    belongs_to :simulation_script, HydraAgent.Simulations.SimulationScript

    has_many :reports, HydraAgent.Simulations.SimulationReport

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  def changeset(pack, attrs) do
    pack
    |> cast(attrs, [
      :workspace_id,
      :run_id,
      :simulation_id,
      :simulation_run_record_id,
      :simulation_version_id,
      :context_pack_id,
      :population_model_id,
      :simulation_script_id,
      :schema_version,
      :protocol_version,
      :setup,
      :metrics,
      :segments,
      :timeline,
      :resource_flows,
      :pivotal_events,
      :representative_traces,
      :model_decisions,
      :scenario_deltas,
      :robustness,
      :uncertainty,
      :grounding_refs,
      :usage,
      :limitations,
      :reference_index,
      :report_generation_cap,
      :content_hash,
      :generated_at
    ])
    |> validate_required([
      :workspace_id,
      :run_id,
      :simulation_id,
      :simulation_run_record_id,
      :simulation_version_id,
      :context_pack_id,
      :population_model_id,
      :simulation_script_id,
      :schema_version,
      :protocol_version,
      :setup,
      :metrics,
      :segments,
      :timeline,
      :resource_flows,
      :pivotal_events,
      :representative_traces,
      :model_decisions,
      :scenario_deltas,
      :robustness,
      :uncertainty,
      :grounding_refs,
      :usage,
      :limitations,
      :reference_index,
      :report_generation_cap,
      :content_hash,
      :generated_at
    ])
    |> validate_number(:schema_version, equal_to: 1)
    |> validate_inclusion(:protocol_version, ["hydra-analysis/v1"])
    |> validate_number(:report_generation_cap,
      greater_than: 0,
      less_than_or_equal_to: 20
    )
    |> validate_length(:metrics, max: 128)
    |> validate_length(:segments, max: 96)
    |> validate_length(:timeline, max: 64)
    |> validate_length(:resource_flows, max: 96)
    |> validate_length(:pivotal_events, max: 32)
    |> validate_length(:representative_traces, max: 32)
    |> validate_length(:model_decisions, max: 96)
    |> validate_length(:scenario_deltas, max: 32)
    |> validate_length(:grounding_refs, max: 240)
    |> validate_length(:limitations, max: 32)
    |> validate_format(:content_hash, ~r/^[a-f0-9]{64}$/)
    |> foreign_key_constraint(:workspace_id)
    |> foreign_key_constraint(:run_id)
    |> foreign_key_constraint(:simulation_id)
    |> foreign_key_constraint(:simulation_run_record_id)
    |> foreign_key_constraint(:simulation_version_id)
    |> foreign_key_constraint(:context_pack_id)
    |> foreign_key_constraint(:population_model_id)
    |> foreign_key_constraint(:simulation_script_id)
    |> unique_constraint(:simulation_run_record_id)
    |> unique_constraint(:run_id)
    |> check_constraint(:content_hash, name: :simulation_analysis_packs_bounds_check)
  end

  def payload(%__MODULE__{} = pack) do
    %{
      "schema_version" => pack.schema_version,
      "protocol_version" => pack.protocol_version,
      "run_id" => to_string(pack.run_id),
      "setup" => pack.setup,
      "metrics" => pack.metrics,
      "segments" => pack.segments,
      "timeline" => pack.timeline,
      "resource_flows" => pack.resource_flows,
      "pivotal_events" => pack.pivotal_events,
      "representative_traces" => pack.representative_traces,
      "model_decisions" => pack.model_decisions,
      "scenario_deltas" => pack.scenario_deltas,
      "robustness" => pack.robustness,
      "uncertainty" => pack.uncertainty,
      "grounding_refs" => pack.grounding_refs,
      "usage" => pack.usage,
      "limitations" => pack.limitations,
      "reference_index" => pack.reference_index,
      "content_hash" => pack.content_hash
    }
  end
end
