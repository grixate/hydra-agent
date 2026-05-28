defmodule HydraAgent.MCP.Server do
  use Ecto.Schema
  import Ecto.Changeset

  @statuses ~w(inactive active paused archived)
  @transports ~w(stdio http sse)
  @trust_levels ~w(sandboxed workspace trusted)
  @health_statuses ~w(unknown healthy unhealthy)

  schema "mcp_servers" do
    field :name, :string
    field :slug, :string
    field :status, :string, default: "inactive"
    field :transport, :string
    field :trust_level, :string, default: "sandboxed"
    field :config, :map, default: %{}
    field :env_refs, {:array, :string}, default: []
    field :include_tools, {:array, :string}, default: []
    field :exclude_tools, {:array, :string}, default: []
    field :resource_access, :boolean, default: false
    field :prompt_access, :boolean, default: false
    field :timeout_ms, :integer, default: 30_000
    field :approval_sensitive, :boolean, default: true
    field :health_status, :string, default: "unknown"
    field :last_checked_at, :utc_datetime_usec
    field :last_error, :map, default: %{}
    field :metadata, :map, default: %{}

    belongs_to :workspace, HydraAgent.Runtime.Workspace

    timestamps(type: :utc_datetime_usec)
  end

  def statuses, do: @statuses
  def transports, do: @transports
  def trust_levels, do: @trust_levels
  def health_statuses, do: @health_statuses

  def changeset(server, attrs) do
    attrs = stringify_keys(attrs)

    server
    |> cast(attrs, [
      :workspace_id,
      :name,
      :slug,
      :status,
      :transport,
      :trust_level,
      :config,
      :env_refs,
      :include_tools,
      :exclude_tools,
      :resource_access,
      :prompt_access,
      :timeout_ms,
      :approval_sensitive,
      :health_status,
      :last_checked_at,
      :last_error,
      :metadata
    ])
    |> validate_required([:workspace_id, :name, :slug, :status, :transport, :trust_level])
    |> validate_format(:slug, ~r/^[a-z0-9][a-z0-9-]*$/)
    |> validate_inclusion(:status, @statuses)
    |> validate_inclusion(:transport, @transports)
    |> validate_inclusion(:trust_level, @trust_levels)
    |> validate_inclusion(:health_status, @health_statuses)
    |> validate_number(:timeout_ms,
      greater_than_or_equal_to: 1_000,
      less_than_or_equal_to: 300_000
    )
    |> validate_env_refs()
    |> validate_config()
    |> validate_env_ref_config()
    |> validate_tool_filters()
    |> assoc_constraint(:workspace)
    |> unique_constraint([:workspace_id, :slug])
  end

  defp validate_env_refs(changeset) do
    validate_change(changeset, :env_refs, fn :env_refs, refs ->
      invalid = Enum.reject(refs, &Regex.match?(~r/^[A-Z][A-Z0-9_]*$/, &1))

      if invalid == [] do
        []
      else
        [env_refs: "must contain only environment variable names: #{Enum.join(invalid, ", ")}"]
      end
    end)
  end

  defp validate_config(changeset) do
    transport = get_field(changeset, :transport)
    config = get_field(changeset, :config) || %{}

    changeset
    |> reject_inline_secret_config(config)
    |> validate_transport_config(transport, config)
  end

  defp reject_inline_secret_config(changeset, config) do
    forbidden =
      config
      |> Map.keys()
      |> Enum.filter(
        &(String.contains?(String.downcase(to_string(&1)), "secret") or
            String.contains?(String.downcase(to_string(&1)), "token") or
            String.contains?(String.downcase(to_string(&1)), "key"))
      )

    if forbidden == [] do
      changeset
    else
      add_error(
        changeset,
        :config,
        "must not contain inline secret-like keys; use env_refs: #{Enum.join(forbidden, ", ")}"
      )
    end
  end

  defp validate_transport_config(changeset, "stdio", config) do
    command = config["command"]

    if is_list(command) and command != [] and Enum.all?(command, &is_binary/1) do
      changeset
    else
      add_error(changeset, :config, "stdio transport requires a string command list")
    end
  end

  defp validate_transport_config(changeset, transport, config)
       when transport in ["http", "sse"] do
    case URI.parse(config["url"] || "") do
      %URI{scheme: scheme, host: host} when scheme in ["http", "https"] and is_binary(host) ->
        changeset

      _uri ->
        add_error(changeset, :config, "#{transport} transport requires an http(s) url")
    end
  end

  defp validate_transport_config(changeset, _transport, _config), do: changeset

  defp validate_env_ref_config(changeset) do
    config = get_field(changeset, :config) || %{}
    env_refs = get_field(changeset, :env_refs) || []
    bearer_env = config["bearer_env"]

    cond do
      is_nil(bearer_env) ->
        changeset

      not Regex.match?(~r/^[A-Z][A-Z0-9_]*$/, bearer_env) ->
        add_error(changeset, :config, "bearer_env must name an environment variable")

      bearer_env not in env_refs ->
        add_error(changeset, :config, "bearer_env must be listed in env_refs")

      true ->
        changeset
    end
  end

  defp validate_tool_filters(changeset) do
    include_tools = get_field(changeset, :include_tools) || []
    exclude_tools = get_field(changeset, :exclude_tools) || []

    overlap = include_tools -- (include_tools -- exclude_tools)

    if overlap == [] do
      changeset
    else
      add_error(changeset, :exclude_tools, "overlaps include_tools: #{Enum.join(overlap, ", ")}")
    end
  end

  defp stringify_keys(map) when is_map(map) do
    Map.new(map, fn {key, value} -> {to_string(key), value} end)
  end
end
