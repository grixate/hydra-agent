defmodule HydraAgent.Simulations.RunSnapshot do
  use Ecto.Schema
  import Ecto.Changeset

  schema "run_snapshots" do
    field :round, :integer
    field :event_sequence, :integer
    field :schema_version, :integer, default: 1
    field :engine_version, :string
    field :payload, :map
    field :state_hash, :string
    field :checksum, :string

    belongs_to :workspace, HydraAgent.Runtime.Workspace
    belongs_to :run, HydraAgent.Runtime.Run
    belongs_to :simulation_run_record, HydraAgent.Simulations.SimulationRunRecord

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  def changeset(snapshot, attrs) do
    snapshot
    |> cast(attrs, [
      :workspace_id,
      :run_id,
      :simulation_run_record_id,
      :round,
      :event_sequence,
      :schema_version,
      :engine_version,
      :payload,
      :state_hash,
      :checksum
    ])
    |> validate_required([
      :workspace_id,
      :run_id,
      :simulation_run_record_id,
      :round,
      :event_sequence,
      :schema_version,
      :engine_version,
      :payload,
      :state_hash,
      :checksum
    ])
    |> validate_number(:round, greater_than_or_equal_to: 0)
    |> validate_number(:event_sequence, greater_than_or_equal_to: 0)
    |> validate_number(:schema_version, equal_to: 1)
    |> validate_format(:state_hash, ~r/^[a-f0-9]{64}$/)
    |> validate_format(:checksum, ~r/^[a-f0-9]{64}$/)
    |> foreign_key_constraint(:workspace_id)
    |> foreign_key_constraint(:run_id)
    |> foreign_key_constraint(:simulation_run_record_id)
    |> unique_constraint([:simulation_run_record_id, :round])
    |> unique_constraint([:run_id, :event_sequence])
    |> check_constraint(:round, name: :run_snapshots_integrity_check)
  end
end
