defmodule HydraAgent.Tools.SourceIngest do
  @behaviour HydraAgent.Tool

  alias HydraAgent.Knowledge

  @impl true
  def spec do
    %{
      name: "source_ingest",
      side_effect_class: "workspace_write",
      timeout_ms: 15_000,
      approval_sensitive: true,
      description: "Record an external or local source as a workspace knowledge node.",
      input_schema: %{
        "type" => "object",
        "required" => ["title"],
        "properties" => %{
          "title" => %{"type" => "string"},
          "url" => %{"type" => "string"},
          "body" => %{"type" => "string"},
          "source_type" => %{"type" => "string"},
          "metadata" => %{"type" => "object"},
          "confidence" => %{"type" => "number"}
        }
      },
      output_schema: %{
        "type" => "object",
        "properties" => %{
          "node_id" => %{"type" => "integer"},
          "title" => %{"type" => "string"},
          "type_key" => %{"type" => "string"}
        }
      }
    }
  end

  @impl true
  def execute(input, context) do
    input = stringify_keys(input || %{})

    attrs = %{
      "workspace_id" => context["workspace_id"] || context[:workspace_id],
      "created_by_agent_id" => context["agent_id"] || context[:agent_id],
      "type_key" => "source",
      "title" => input["title"],
      "body" => input["body"],
      "confidence" => input["confidence"] || 0.7,
      "importance" => input["importance"] || 0.5,
      "attributes" => %{
        "url" => input["url"],
        "source_type" => input["source_type"] || "unknown",
        "metadata" => input["metadata"] || %{}
      },
      "provenance" => %{
        "kind" => "source_ingest",
        "url" => input["url"],
        "run_id" => context["run_id"],
        "run_step_id" => context["run_step_id"]
      }
    }

    create_node(attrs)
  end

  defp create_node(attrs) do
    case Knowledge.create_node(attrs) do
      {:ok, node} ->
        {:ok, %{"node_id" => node.id, "title" => node.title, "type_key" => node.type_key}}

      {:error, changeset} ->
        {:error, %{"reason" => "invalid_source", "errors" => errors_json(changeset)}}
    end
  end

  defp stringify_keys(map), do: Map.new(map, fn {key, value} -> {to_string(key), value} end)

  defp errors_json(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
      Enum.reduce(opts, message, fn {key, value}, acc ->
        String.replace(acc, "%{#{key}}", to_string(value))
      end)
    end)
  end
end
