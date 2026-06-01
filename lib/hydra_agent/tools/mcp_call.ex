defmodule HydraAgent.Tools.McpCall do
  @behaviour HydraAgent.Tool

  alias HydraAgent.MCP

  @impl true
  def spec do
    %{
      name: "mcp_call",
      side_effect_class: "mcp",
      timeout_ms: 60_000,
      approval_sensitive: true,
      parallel_safe: false,
      description: "Call an allowlisted tool on an active configured MCP server.",
      input_schema: %{
        "type" => "object",
        "required" => ["tool_name"],
        "properties" => %{
          "server_id" => %{"type" => "integer"},
          "server_slug" => %{"type" => "string"},
          "tool_name" => %{"type" => "string"},
          "params" => %{"type" => "object"}
        }
      },
      output_schema: %{
        "type" => "object",
        "properties" => %{
          "server_id" => %{"type" => "integer"},
          "server_slug" => %{"type" => "string"},
          "tool_name" => %{"type" => "string"},
          "result" => %{"type" => "object"}
        }
      }
    }
  end

  @impl true
  def execute(input, context) do
    input = stringify_keys(input || %{})
    workspace_id = context["workspace_id"] || context[:workspace_id]

    with {:ok, server} <- MCP.resolve_server(workspace_id, input),
         {:ok, tool_name} <- tool_name(input) do
      MCP.execute_tool(server, tool_name, input["params"] || %{}, context)
    else
      {:blocked, reason, metadata} -> {:error, %{"reason" => reason, "metadata" => metadata}}
      {:error, error} -> {:error, error}
    end
  end

  defp tool_name(%{"tool_name" => tool_name}) when is_binary(tool_name) and tool_name != "",
    do: {:ok, tool_name}

  defp tool_name(_input), do: {:error, %{"reason" => "mcp_tool_name_required"}}

  defp stringify_keys(map), do: Map.new(map, fn {key, value} -> {to_string(key), value} end)
end
