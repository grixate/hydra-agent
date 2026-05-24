defmodule HydraAgent.Tools.RelationshipCreate do
  @behaviour HydraAgent.Tool

  alias HydraAgent.Knowledge

  @impl true
  def spec do
    %{
      name: "relationship_create",
      side_effect_class: "workspace_write",
      timeout_ms: 15_000,
      approval_sensitive: true,
      description: "Create a typed edge between two knowledge nodes.",
      input_schema: %{
        "type" => "object",
        "required" => ["from_node_id", "to_node_id", "type_key"],
        "properties" => %{
          "from_node_id" => %{"type" => "integer"},
          "to_node_id" => %{"type" => "integer"},
          "type_key" => %{"type" => "string"},
          "attributes" => %{"type" => "object"},
          "confidence" => %{"type" => "number"},
          "provenance" => %{"type" => "object"}
        }
      },
      output_schema: %{
        "type" => "object",
        "properties" => %{
          "relationship_id" => %{"type" => "integer"},
          "type_key" => %{"type" => "string"}
        }
      }
    }
  end

  @impl true
  def execute(input, context) do
    attrs =
      input
      |> stringify_keys()
      |> Map.put_new("workspace_id", context["workspace_id"] || context[:workspace_id])
      |> Map.put_new("created_by_agent_id", context["agent_id"] || context[:agent_id])

    case Knowledge.create_relationship(attrs) do
      {:ok, relationship} ->
        {:ok, %{"relationship_id" => relationship.id, "type_key" => relationship.type_key}}

      {:error, changeset} ->
        {:error, %{"reason" => "invalid_relationship", "errors" => errors_json(changeset)}}
    end
  end

  defp stringify_keys(map) when is_map(map) do
    Map.new(map, fn {key, value} -> {to_string(key), value} end)
  end

  defp errors_json(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
      Enum.reduce(opts, message, fn {key, value}, acc ->
        String.replace(acc, "%{#{key}}", to_string(value))
      end)
    end)
  end
end
