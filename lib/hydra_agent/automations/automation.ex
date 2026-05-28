defmodule HydraAgent.Automations.Automation do
  use Ecto.Schema
  import Ecto.Changeset

  @statuses ~w(active paused archived)

  schema "automations" do
    field :name, :string
    field :slug, :string
    field :status, :string, default: "active"
    field :cron_expression, :string
    field :timezone, :string, default: "Etc/UTC"
    field :prompt, :string
    field :last_run_at, :utc_datetime_usec
    field :next_run_at, :utc_datetime_usec
    field :last_error, :map, default: %{}
    field :metadata, :map, default: %{}

    belongs_to :workspace, HydraAgent.Runtime.Workspace
    belongs_to :agent, HydraAgent.Runtime.AgentProfile

    timestamps(type: :utc_datetime_usec)
  end

  def statuses, do: @statuses

  def changeset(automation, attrs) do
    automation
    |> cast(attrs, [
      :workspace_id,
      :agent_id,
      :name,
      :slug,
      :status,
      :cron_expression,
      :timezone,
      :prompt,
      :last_run_at,
      :next_run_at,
      :last_error,
      :metadata
    ])
    |> validate_required([
      :workspace_id,
      :agent_id,
      :name,
      :slug,
      :status,
      :cron_expression,
      :prompt
    ])
    |> validate_format(:slug, ~r/^[a-z0-9][a-z0-9-]*$/)
    |> validate_inclusion(:status, @statuses)
    |> validate_timezone()
    |> validate_cron_expression()
    |> assoc_constraint(:workspace)
    |> assoc_constraint(:agent)
    |> unique_constraint([:workspace_id, :slug])
  end

  defp validate_cron_expression(changeset) do
    validate_change(changeset, :cron_expression, fn :cron_expression, expression ->
      case Crontab.CronExpression.Parser.parse(expression) do
        {:ok, _cron} -> []
        {:error, reason} -> [cron_expression: "is invalid: #{reason}"]
      end
    end)
  end

  defp validate_timezone(changeset) do
    validate_change(changeset, :timezone, fn :timezone, timezone ->
      case DateTime.now(timezone) do
        {:ok, _datetime} ->
          []

        {:error, reason} ->
          [timezone: "is not supported by the configured timezone database: #{reason}"]
      end
    end)
  end
end
