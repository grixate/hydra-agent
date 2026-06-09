defmodule HydraAgent.Tools.PluginProxy do
  @moduledoc """
  Executes policy-authorized plugin tool declarations through supported adapters.
  """

  alias HydraAgent.MCP
  alias HydraAgent.Tools.ProjectSkillRun

  def execute(input, context, spec) do
    input = stringify_keys(input || %{})
    context = stringify_keys(context || %{})
    execution = stringify_keys(get_in(spec, [:plugin, "execution"]) || %{})

    case execution["type"] do
      "project_skill" ->
        execute_project_skill(input, context, execution)

      "mcp" ->
        execute_mcp(input, context, execution)

      "trusted_module" ->
        {:error, %{"reason" => "trusted_plugin_tool_execution_not_enabled"}}

      "webhook" ->
        {:error, %{"reason" => "webhook_plugin_tool_execution_not_enabled"}}

      type ->
        {:error, %{"reason" => "unsupported_plugin_tool_execution", "type" => type}}
    end
  end

  defp execute_project_skill(input, context, execution) do
    tool_input =
      execution
      |> Map.take(["skill_slug", "entrypoint", "runtime"])
      |> Map.merge(input)

    ProjectSkillRun.execute(tool_input, context)
  end

  defp execute_mcp(input, context, execution) do
    tool_name = execution["tool_name"] || input["tool_name"]

    params =
      input["params"] || Map.drop(input, ["server_id", "server_slug", "tool_name", "params"])

    mcp_input =
      execution
      |> Map.take(["server_id", "server_slug"])
      |> Map.merge(%{"tool_name" => tool_name, "params" => params})

    with {:ok, server} <- MCP.resolve_server(context["workspace_id"], mcp_input),
         true <- is_binary(tool_name) and tool_name != "" do
      MCP.execute_tool(server, tool_name, params, context)
    else
      false -> {:error, %{"reason" => "mcp_tool_name_required"}}
      {:blocked, reason, metadata} -> {:error, %{"reason" => reason, "metadata" => metadata}}
      {:error, error} -> {:error, error}
    end
  end

  defp stringify_keys(map) when is_map(map),
    do: Map.new(map, fn {key, value} -> {to_string(key), value} end)
end
