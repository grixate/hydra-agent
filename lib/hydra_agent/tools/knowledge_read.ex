defmodule HydraAgent.Tools.KnowledgeRead do
  @behaviour HydraAgent.Tool

  alias HydraAgent.Knowledge

  @impl true
  def spec do
    %{
      name: "knowledge_read",
      side_effect_class: "read_only",
      timeout_ms: 10_000,
      approval_sensitive: false,
      description: "Read one workspace-scoped knowledge node by id.",
      input_schema: %{
        "type" => "object",
        "required" => ["id"],
        "properties" => %{"id" => %{"type" => "integer"}}
      },
      output_schema: %{"type" => "object", "properties" => %{"node" => %{"type" => "object"}}}
    }
  end

  @impl true
  def execute(input, _context) do
    node = Knowledge.get_node!(input["id"] || input[:id])

    {:ok,
     %{
       "node" => %{
         "id" => node.id,
         "workspace_id" => node.workspace_id,
         "type_key" => node.type_key,
         "title" => node.title,
         "body" => node.body,
         "status" => node.status,
         "attributes" => node.attributes,
         "importance" => node.importance,
         "confidence" => node.confidence,
         "provenance" => node.provenance
       }
     }}
  rescue
    Ecto.NoResultsError -> {:error, %{"reason" => "node_not_found"}}
  end
end
