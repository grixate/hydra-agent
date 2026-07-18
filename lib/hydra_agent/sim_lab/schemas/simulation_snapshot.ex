defmodule HydraAgent.SimLab.Schemas.SimulationSnapshot do
  use Ecto.Schema
  import Ecto.Changeset

  schema "sim_lab_snapshots" do
    field :tick, :integer
    field :label, :string
    field :clusters, :map, default: %{}
    field :metrics, :map, default: %{}
    field :decision_counts, :map, default: %{}
    field :cost, :map, default: %{}
    field :insight_refs, {:array, :string}, default: []

    belongs_to :run, HydraAgent.SimLab.Schemas.SimulationRun

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  def changeset(snapshot, attrs) do
    snapshot
    |> cast(attrs, [
      :run_id,
      :tick,
      :label,
      :clusters,
      :metrics,
      :decision_counts,
      :cost,
      :insight_refs
    ])
    |> validate_required([:run_id, :tick, :label])
    |> validate_number(:tick, greater_than_or_equal_to: 0)
    |> unique_constraint([:run_id, :tick])
    |> foreign_key_constraint(:run_id)
  end
end
