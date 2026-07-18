defmodule HydraAgent.MCP.SecurityPolicy do
  @moduledoc """
  Deployment-owned allowlists for MCP credentials and local stdio processes.

  Workspace configuration may select only values an operator has explicitly
  exposed. Empty or malformed deployment configuration therefore disables the
  corresponding capability.
  """

  @spec authorize_executable(term()) :: :ok | {:error, map()}
  def authorize_executable(program) when is_binary(program) and program != "" do
    if program in configured_values(:stdio_executable_allowlist) do
      :ok
    else
      {:error,
       %{
         "reason" => "mcp_stdio_executable_not_allowed",
         "program" => program
       }}
    end
  end

  def authorize_executable(_program),
    do: {:error, %{"reason" => "mcp_stdio_executable_not_allowed"}}

  @spec authorize_env_refs(term()) :: :ok | {:error, map()}
  def authorize_env_refs(refs) when is_list(refs) do
    case disallowed_env_refs(refs) do
      [] ->
        :ok

      disallowed ->
        {:error,
         %{
           "reason" => "mcp_env_refs_not_allowed",
           "env_refs" => disallowed
         }}
    end
  end

  def authorize_env_refs(_refs),
    do: {:error, %{"reason" => "mcp_env_refs_not_allowed", "env_refs" => []}}

  @spec executable_allowed?(term()) :: boolean()
  def executable_allowed?(program), do: authorize_executable(program) == :ok

  @spec disallowed_env_refs(term()) :: [term()]
  def disallowed_env_refs(refs) when is_list(refs) do
    allowed = MapSet.new(configured_values(:env_ref_allowlist))

    refs
    |> Enum.reject(&MapSet.member?(allowed, &1))
    |> Enum.uniq()
    |> Enum.sort()
  end

  def disallowed_env_refs(_refs), do: []

  defp configured_values(key) do
    configured = Application.get_env(:hydra_agent, :mcp_security, [])

    configured
    |> case do
      values when is_list(values) -> Keyword.get(values, key, [])
      values when is_map(values) -> Map.get(values, key, [])
      _invalid -> []
    end
    |> case do
      values when is_list(values) ->
        values
        |> Enum.filter(&(is_binary(&1) and String.trim(&1) != ""))
        |> Enum.map(&String.trim/1)
        |> Enum.uniq()

      _invalid ->
        []
    end
  end
end
