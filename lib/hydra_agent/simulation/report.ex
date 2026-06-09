defmodule HydraAgent.Simulation.Report do
  use Ecto.Schema
  import Ecto.Changeset

  schema "simulation_reports" do
    field :content, :string
    field :statistical_summary, :map, default: %{}
    field :generated_at, :utc_datetime_usec

    belongs_to :simulation, HydraAgent.Simulation.Simulation

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(report, attrs) do
    report
    |> cast(attrs, [:simulation_id, :content, :statistical_summary, :generated_at])
    |> validate_required([:simulation_id, :content])
    |> assoc_constraint(:simulation)
  end
end
