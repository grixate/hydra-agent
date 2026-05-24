defmodule HydraAgent.Evals.Suite do
  use Ecto.Schema
  import Ecto.Changeset

  @statuses ~w(active archived)

  schema "eval_suites" do
    field :name, :string
    field :slug, :string
    field :description, :string
    field :status, :string, default: "active"
    field :metadata, :map, default: %{}

    belongs_to :workspace, HydraAgent.Runtime.Workspace
    has_many :cases, HydraAgent.Evals.Case
    has_many :runs, HydraAgent.Evals.Run

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(suite, attrs) do
    suite
    |> cast(attrs, [:workspace_id, :name, :slug, :description, :status, :metadata])
    |> validate_required([:workspace_id, :name, :slug, :status])
    |> validate_format(:slug, ~r/^[a-z0-9][a-z0-9-]*$/)
    |> validate_inclusion(:status, @statuses)
    |> assoc_constraint(:workspace)
    |> unique_constraint([:workspace_id, :slug])
  end
end
