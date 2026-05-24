defmodule HydraAgent.Evals.Case do
  use Ecto.Schema
  import Ecto.Changeset

  schema "eval_cases" do
    field :name, :string
    field :slug, :string
    field :prompt, :string
    field :expected, :map, default: %{}
    field :scoring, :map, default: %{}
    field :metadata, :map, default: %{}

    belongs_to :workspace, HydraAgent.Runtime.Workspace
    belongs_to :suite, HydraAgent.Evals.Suite

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(eval_case, attrs) do
    eval_case
    |> cast(attrs, [
      :workspace_id,
      :suite_id,
      :name,
      :slug,
      :prompt,
      :expected,
      :scoring,
      :metadata
    ])
    |> validate_required([:workspace_id, :suite_id, :name, :slug, :prompt])
    |> validate_format(:slug, ~r/^[a-z0-9][a-z0-9-]*$/)
    |> assoc_constraint(:workspace)
    |> assoc_constraint(:suite)
    |> unique_constraint([:suite_id, :slug])
  end
end
