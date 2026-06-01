defmodule HydraAgent.Tools.KnowledgeWrite do
  @behaviour HydraAgent.Tool

  alias HydraAgent.Knowledge

  @impl true
  def spec do
    %{
      name: "knowledge_write",
      side_effect_class: "workspace_write",
      timeout_ms: 15_000,
      approval_sensitive: true,
      description: "Create a knowledge node in the current workspace.",
      input_schema: %{
        "type" => "object",
        "required" => ["type_key", "title"],
        "properties" => %{
          "type_key" => %{"type" => "string"},
          "title" => %{"type" => "string"},
          "body" => %{"type" => "string"},
          "attributes" => %{"type" => "object"},
          "importance" => %{"type" => "number"},
          "confidence" => %{"type" => "number"},
          "provenance" => %{"type" => "object"}
        }
      },
      output_schema: %{
        "type" => "object",
        "properties" => %{
          "node_id" => %{"type" => "integer"},
          "title" => %{"type" => "string"}
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
      |> Map.update("provenance", run_provenance(context), fn
        provenance when is_map(provenance) -> Map.merge(run_provenance(context), provenance)
        _provenance -> run_provenance(context)
      end)

    case Knowledge.create_node(attrs) do
      {:ok, node} ->
        {:ok, %{"node_id" => node.id, "title" => node.title}}

      {:error, changeset} ->
        {:error, %{"reason" => "invalid_node", "errors" => errors_json(changeset)}}
    end
  end

  defp stringify_keys(map) when is_map(map) do
    Map.new(map, fn {key, value} -> {to_string(key), value} end)
  end

  defp run_provenance(context) do
    %{
      "kind" => "knowledge_write",
      "run_id" => context["run_id"] || context[:run_id],
      "run_step_id" => context["run_step_id"] || context[:run_step_id]
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp errors_json(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
      Enum.reduce(opts, message, fn {key, value}, acc ->
        String.replace(acc, "%{#{key}}", to_string(value))
      end)
    end)
  end
end
