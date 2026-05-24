defmodule HydraAgent.Evals.Result do
  use Ecto.Schema
  import Ecto.Changeset

  @statuses ~w(pending passed failed errored skipped)

  schema "eval_results" do
    field :status, :string, default: "pending"
    field :score, :float
    field :output, :map, default: %{}
    field :error, :map, default: %{}
    field :metadata, :map, default: %{}

    belongs_to :workspace, HydraAgent.Runtime.Workspace
    belongs_to :eval_run, HydraAgent.Evals.Run
    belongs_to :eval_case, HydraAgent.Evals.Case

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(result, attrs) do
    result
    |> cast(attrs, [
      :workspace_id,
      :eval_run_id,
      :eval_case_id,
      :status,
      :score,
      :output,
      :error,
      :metadata
    ])
    |> validate_required([:workspace_id, :eval_run_id, :eval_case_id, :status])
    |> validate_inclusion(:status, @statuses)
    |> validate_number(:score, greater_than_or_equal_to: 0.0, less_than_or_equal_to: 1.0)
    |> assoc_constraint(:workspace)
    |> assoc_constraint(:eval_run)
    |> assoc_constraint(:eval_case)
    |> unique_constraint([:eval_run_id, :eval_case_id])
  end
end
