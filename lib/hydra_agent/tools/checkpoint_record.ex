defmodule HydraAgent.Tools.CheckpointRecord do
  use Ecto.Schema
  import Ecto.Changeset

  schema "tool_checkpoints" do
    field :tool_name, :string
    field :path, :string
    field :relative_path, :string
    field :checkpoint_path, :string
    field :sha256, :string
    field :existed, :boolean, default: false
    field :restored_at, :utc_datetime_usec
    field :metadata, :map, default: %{}

    belongs_to :workspace, HydraAgent.Runtime.Workspace
    belongs_to :run, HydraAgent.Runtime.Run
    belongs_to :run_step, HydraAgent.Runtime.RunStep

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(record, attrs) do
    record
    |> cast(attrs, [
      :workspace_id,
      :run_id,
      :run_step_id,
      :tool_name,
      :path,
      :relative_path,
      :checkpoint_path,
      :sha256,
      :existed,
      :restored_at,
      :metadata
    ])
    |> validate_required([:path, :existed])
    |> assoc_constraint(:workspace)
    |> assoc_constraint(:run)
    |> assoc_constraint(:run_step)
  end
end
