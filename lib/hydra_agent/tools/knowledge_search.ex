defmodule HydraAgent.Tools.KnowledgeSearch do
  @behaviour HydraAgent.Tool

  alias HydraAgent.Knowledge

  @impl true
  def spec do
    %{
      name: "knowledge_search",
      side_effect_class: "read_only",
      timeout_ms: 10_000,
      approval_sensitive: false,
      description: "Search workspace-scoped knowledge nodes.",
      input_schema: %{
        "type" => "object",
        "required" => ["query"],
        "properties" => %{
          "query" => %{"type" => "string"},
          "limit" => %{"type" => "integer", "minimum" => 1, "maximum" => 100}
        }
      },
      output_schema: %{
        "type" => "object",
        "properties" => %{
          "nodes" => %{"type" => "array"},
          "count" => %{"type" => "integer"}
        }
      }
    }
  end

  @impl true
  def execute(input, context) do
    workspace_id = context["workspace_id"] || context[:workspace_id]
    query = input["query"] || input[:query] || ""
    limit = input["limit"] || input[:limit] || 20

    nodes =
      Knowledge.search_nodes(workspace_id, query, limit: limit)
      |> Enum.map(&node_json/1)

    {:ok, %{"nodes" => nodes, "count" => length(nodes)}}
  end

  defp node_json(node) do
    %{
      "id" => node.id,
      "type_key" => node.type_key,
      "title" => node.title,
      "body" => node.body,
      "status" => node.status,
      "importance" => node.importance,
      "confidence" => node.confidence
    }
  end
end
