defmodule HydraAgent.Memory do
  @moduledoc """
  Recall layer for agent context.

  V1 composes high-signal workspace knowledge nodes into compact prompt context.
  Later versions can add vector search, recency decay, and conflict handling
  without changing the chat service contract.
  """

  alias HydraAgent.Knowledge
  alias HydraAgent.Runtime.AgentProfile

  def recall(%AgentProfile{} = agent, query, opts \\ []) do
    limit = Keyword.get(opts, :limit, 6)

    nodes =
      Knowledge.search_nodes(agent.workspace_id, query, limit: limit)
      |> Enum.filter(&in_scope?(&1, agent))

    %{
      "query" => query,
      "nodes" => Enum.map(nodes, &node_context/1),
      "count" => length(nodes)
    }
  end

  def format_context(%{"nodes" => []}), do: ""

  def format_context(%{"nodes" => nodes}) do
    nodes
    |> Enum.map_join("\n", fn node ->
      "- [#{node["type_key"]}:#{node["id"]}] #{node["title"]}: #{node["body"]}"
    end)
  end

  def curate_workspace(workspace_id, opts \\ []) do
    archive_below = Keyword.get(opts, :archive_below_confidence, 0.2)
    dry_run? = Keyword.get(opts, :dry_run?, true)

    low_confidence =
      workspace_id
      |> Knowledge.list_nodes(status: "active", limit: 500)
      |> Enum.filter(&(&1.confidence < archive_below))

    duplicates = Knowledge.duplicate_title_groups(workspace_id)

    archived =
      if dry_run? do
        []
      else
        Enum.map(low_confidence, fn node ->
          {:ok, updated} =
            Knowledge.update_node(node, %{
              status: "archived",
              attributes: Map.put(node.attributes || %{}, "archived_reason", "low_confidence")
            })

          updated
        end)
      end

    %{
      "dry_run" => dry_run?,
      "archive_below_confidence" => archive_below,
      "low_confidence_candidates" => Enum.map(low_confidence, &node_context/1),
      "archived_node_ids" => Enum.map(archived, & &1.id),
      "duplicate_title_groups" =>
        Enum.map(duplicates, fn {title, count} -> %{"title" => title, "count" => count} end)
    }
  end

  defp in_scope?(node, %AgentProfile{} = agent) do
    scopes = agent.knowledge_scopes || []
    "workspace" in scopes or node.type_key in scopes
  end

  defp node_context(node) do
    %{
      "id" => node.id,
      "type_key" => node.type_key,
      "title" => node.title,
      "body" => node.body,
      "confidence" => node.confidence,
      "importance" => node.importance,
      "provenance" => node.provenance
    }
  end
end
