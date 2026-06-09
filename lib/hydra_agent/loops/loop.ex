defmodule HydraAgent.Loops.Loop do
  use Ecto.Schema
  import Ecto.Changeset

  @statuses ~w(draft active paused blocked archived)
  @trigger_types ~w(manual cron)
  @autonomy_levels HydraAgent.Runtime.Autonomy.autonomy_levels()
  @default_guardrails %{
    "max_iterations_per_tick" => 1,
    "max_child_runs_per_tick" => 3,
    "max_consecutive_no_progress" => 3,
    "max_runtime_seconds" => 300
  }

  schema "loops" do
    field :name, :string
    field :slug, :string
    field :status, :string, default: "draft"
    field :purpose, :string
    field :trigger, :map, default: %{"type" => "manual"}
    field :body, :map, default: %{}
    field :autonomy_level, :string, default: "recommend"
    field :budget, :map, default: %{}
    field :guardrails, :map, default: @default_guardrails
    field :state, :map, default: %{}
    field :last_error, :map, default: %{}
    field :next_tick_at, :utc_datetime_usec
    field :last_tick_at, :utc_datetime_usec
    field :lease_owner, :string
    field :lease_expires_at, :utc_datetime_usec
    field :metadata, :map, default: %{}

    belongs_to :workspace, HydraAgent.Runtime.Workspace
    belongs_to :mission, HydraAgent.Runtime.Mission
    belongs_to :supervisor_agent, HydraAgent.Runtime.AgentProfile
    belongs_to :verifier_agent, HydraAgent.Runtime.AgentProfile
    has_many :runs, HydraAgent.Runtime.Run, foreign_key: :loop_id

    timestamps(type: :utc_datetime_usec)
  end

  def statuses, do: @statuses
  def trigger_types, do: @trigger_types
  def default_guardrails, do: @default_guardrails

  def changeset(loop, attrs) do
    loop
    |> cast(attrs, [
      :workspace_id,
      :mission_id,
      :supervisor_agent_id,
      :verifier_agent_id,
      :name,
      :slug,
      :status,
      :purpose,
      :trigger,
      :body,
      :autonomy_level,
      :budget,
      :guardrails,
      :state,
      :last_error,
      :next_tick_at,
      :last_tick_at,
      :lease_owner,
      :lease_expires_at,
      :metadata
    ])
    |> put_slug()
    |> put_default_maps()
    |> validate_required([:workspace_id, :name, :slug, :status, :purpose, :autonomy_level])
    |> validate_format(:slug, ~r/^[a-z0-9][a-z0-9-]*$/)
    |> validate_inclusion(:status, @statuses)
    |> validate_inclusion(:autonomy_level, @autonomy_levels)
    |> validate_trigger()
    |> validate_guardrails()
    |> assoc_constraint(:workspace)
    |> assoc_constraint(:mission)
    |> assoc_constraint(:supervisor_agent)
    |> assoc_constraint(:verifier_agent)
    |> unique_constraint([:workspace_id, :slug])
  end

  defp put_slug(changeset) do
    case get_field(changeset, :slug) do
      value when is_binary(value) and value != "" ->
        update_change(changeset, :slug, &slugify/1)

      _value ->
        put_change(changeset, :slug, slugify(get_field(changeset, :name) || "loop"))
    end
  end

  defp put_default_maps(changeset) do
    changeset
    |> put_map_default(:trigger, %{"type" => "manual"})
    |> put_map_default(:body, %{})
    |> put_map_default(:budget, %{})
    |> put_map_default(:guardrails, @default_guardrails)
    |> update_change(:guardrails, &Map.merge(@default_guardrails, stringify_keys(&1 || %{})))
    |> put_map_default(:state, %{})
    |> put_map_default(:last_error, %{})
    |> put_map_default(:metadata, %{})
  end

  defp put_map_default(changeset, field, default) do
    case get_field(changeset, field) do
      value when is_map(value) -> changeset
      _value -> put_change(changeset, field, default)
    end
  end

  defp validate_trigger(changeset) do
    validate_change(changeset, :trigger, fn :trigger, trigger ->
      trigger = stringify_keys(trigger || %{})
      type = trigger["type"] || "manual"

      cond do
        type not in @trigger_types ->
          [trigger: "type must be one of #{Enum.join(@trigger_types, ", ")}"]

        type == "cron" and blank?(trigger["cron_expression"]) ->
          [trigger: "cron trigger requires cron_expression"]

        type == "cron" and invalid_cron?(trigger["cron_expression"]) ->
          [trigger: "cron_expression is invalid"]

        type == "cron" and invalid_timezone?(trigger["timezone"] || "Etc/UTC") ->
          [trigger: "timezone is not supported by the configured timezone database"]

        true ->
          []
      end
    end)
  end

  defp validate_guardrails(changeset) do
    validate_change(changeset, :guardrails, fn :guardrails, guardrails ->
      guardrails = stringify_keys(guardrails || %{})

      ~w(max_iterations_per_tick max_child_runs_per_tick max_consecutive_no_progress max_runtime_seconds token_limit)
      |> Enum.flat_map(&number_guardrail_error(guardrails, &1))
      |> Kernel.++(cost_guardrail_error(guardrails))
    end)
  end

  defp number_guardrail_error(guardrails, key) do
    case guardrails[key] do
      nil -> []
      value when is_integer(value) and value >= 0 -> []
      value when is_binary(value) -> parse_integer_guardrail(value, key)
      _value -> [guardrails: "#{key} must be a non-negative integer"]
    end
  end

  defp parse_integer_guardrail(value, key) do
    case Integer.parse(value) do
      {integer, ""} when integer >= 0 -> []
      _error -> [guardrails: "#{key} must be a non-negative integer"]
    end
  end

  defp cost_guardrail_error(guardrails) do
    case guardrails["cost_limit"] do
      nil -> []
      value when is_integer(value) and value >= 0 -> []
      value when is_float(value) and value >= 0 -> []
      value when is_binary(value) -> parse_decimal_guardrail(value)
      _value -> [guardrails: "cost_limit must be a non-negative number"]
    end
  end

  defp parse_decimal_guardrail(value) do
    case Decimal.parse(value) do
      {%Decimal{} = decimal, ""} ->
        if Decimal.compare(decimal, Decimal.new(0)) in [:gt, :eq],
          do: [],
          else: [guardrails: "cost_limit must be a non-negative number"]

      _error ->
        [guardrails: "cost_limit must be a non-negative number"]
    end
  end

  defp invalid_cron?(expression) do
    case Crontab.CronExpression.Parser.parse(expression) do
      {:ok, _cron} -> false
      {:error, _reason} -> true
    end
  end

  defp invalid_timezone?(timezone) do
    case DateTime.now(timezone) do
      {:ok, _datetime} -> false
      {:error, _reason} -> true
    end
  end

  defp slugify(value) do
    value
    |> to_string()
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "-")
    |> String.trim("-")
    |> case do
      "" -> "loop"
      slug -> slug
    end
  end

  defp stringify_keys(map) when is_map(map),
    do: Map.new(map, fn {key, value} -> {to_string(key), value} end)

  defp blank?(value), do: is_nil(value) or String.trim(to_string(value)) == ""
end
