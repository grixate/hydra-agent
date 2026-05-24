defmodule HydraAgent.Evals.Run do
  use Ecto.Schema
  import Ecto.Changeset

  @statuses ~w(planned running completed failed canceled)

  schema "eval_runs" do
    field :status, :string, default: "planned"
    field :summary, :map, default: %{}
    field :started_at, :utc_datetime_usec
    field :completed_at, :utc_datetime_usec
    field :metadata, :map, default: %{}

    belongs_to :workspace, HydraAgent.Runtime.Workspace
    belongs_to :suite, HydraAgent.Evals.Suite
    belongs_to :agent, HydraAgent.Runtime.AgentProfile
    has_many :results, HydraAgent.Evals.Result, foreign_key: :eval_run_id

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(run, attrs) do
    run
    |> cast(attrs, [
      :workspace_id,
      :suite_id,
      :agent_id,
      :status,
      :summary,
      :started_at,
      :completed_at,
      :metadata
    ])
    |> validate_required([:workspace_id, :suite_id, :status])
    |> validate_inclusion(:status, @statuses)
    |> assoc_constraint(:workspace)
    |> assoc_constraint(:suite)
    |> assoc_constraint(:agent)
  end
end
