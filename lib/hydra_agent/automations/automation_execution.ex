defmodule HydraAgent.Automations.AutomationExecution do
  @moduledoc """
  Durable, inspectable claim for one automation occurrence.

  Claims are at-most-once: a claimed or running occurrence is never
  automatically retried because its external side-effect state may be unknown.
  """

  use Ecto.Schema
  import Ecto.Changeset
  import Ecto.Query

  alias HydraAgent.Automations.Automation
  alias HydraAgent.Runtime.Run

  @statuses ~w(claimed running completed failed blocked)
  @triggers ~w(scheduled manual)

  schema "automation_executions" do
    field :trigger, :string
    field :status, :string, default: "claimed"
    field :scheduled_for, :utc_datetime_usec
    field :next_scheduled_for, :utc_datetime_usec
    field :claimed_at, :utc_datetime_usec
    field :started_at, :utc_datetime_usec
    field :finished_at, :utc_datetime_usec
    field :result, :map, default: %{}
    field :last_error, :map, default: %{}
    field :metadata, :map, default: %{}

    belongs_to :workspace, HydraAgent.Runtime.Workspace
    belongs_to :automation, Automation
    belongs_to :run, Run

    timestamps(type: :utc_datetime_usec)
  end

  def statuses, do: @statuses
  def triggers, do: @triggers

  def changeset(execution, attrs) do
    execution
    |> cast(attrs, [
      :workspace_id,
      :automation_id,
      :run_id,
      :trigger,
      :status,
      :scheduled_for,
      :next_scheduled_for,
      :claimed_at,
      :started_at,
      :finished_at,
      :result,
      :last_error,
      :metadata
    ])
    |> validate_required([
      :workspace_id,
      :automation_id,
      :trigger,
      :status,
      :scheduled_for,
      :next_scheduled_for,
      :claimed_at
    ])
    |> validate_inclusion(:trigger, @triggers)
    |> validate_inclusion(:status, @statuses)
    |> validate_parent_workspaces()
    |> assoc_constraint(:workspace)
    |> assoc_constraint(:automation)
    |> assoc_constraint(:run)
    |> unique_constraint([:automation_id, :scheduled_for],
      name: :automation_executions_occurrence_index
    )
  end

  defp validate_parent_workspaces(changeset) do
    prepare_changes(changeset, fn prepared ->
      workspace_id = get_field(prepared, :workspace_id)
      automation_id = get_field(prepared, :automation_id)
      run_id = get_field(prepared, :run_id)

      prepared
      |> validate_parent_workspace(
        :automation_id,
        from(automation in Automation,
          where: automation.id == ^automation_id and automation.workspace_id == ^workspace_id
        )
      )
      |> maybe_validate_run_workspace(run_id, workspace_id)
    end)
  end

  defp maybe_validate_run_workspace(changeset, nil, _workspace_id), do: changeset

  defp maybe_validate_run_workspace(changeset, run_id, workspace_id) do
    validate_parent_workspace(
      changeset,
      :run_id,
      from(run in Run, where: run.id == ^run_id and run.workspace_id == ^workspace_id)
    )
  end

  defp validate_parent_workspace(changeset, field, query) do
    if changeset.repo.exists?(query) do
      changeset
    else
      add_error(changeset, field, "must belong to the same workspace")
    end
  end
end
