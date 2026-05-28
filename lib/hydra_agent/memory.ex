defmodule HydraAgent.Memory do
  @moduledoc """
  Recall layer for agent context.

  V1 composes high-signal workspace knowledge nodes into compact prompt context.
  Later versions can add vector search, recency decay, and conflict handling
  without changing the chat service contract.
  """

  alias HydraAgent.Knowledge
  alias HydraAgent.Knowledge.Node
  alias HydraAgent.Repo
  alias HydraAgent.Runtime.AgentProfile
  alias HydraAgent.Runtime.Run

  def recall(%AgentProfile{} = agent, query, opts \\ []) do
    limit = Keyword.get(opts, :limit, 6)

    nodes =
      Knowledge.search_nodes(agent.workspace_id, query, limit: limit)
      |> Enum.filter(&(recallable?(&1) and in_scope?(&1, agent)))

    %{
      "query" => query,
      "nodes" => Enum.map(nodes, &node_context/1),
      "count" => length(nodes)
    }
  end

  def propose_node(%AgentProfile{} = agent, attrs, opts \\ []) when is_map(attrs) do
    attrs = stringify_keys(attrs)
    attributes = Map.merge(%{"proposal_status" => "pending"}, attrs["attributes"] || %{})

    provenance =
      %{
        "kind" => "memory_proposal",
        "agent_id" => agent.id,
        "run_id" => attrs["run_id"] || opt(opts, :run_id),
        "run_step_id" => attrs["run_step_id"] || opt(opts, :run_step_id),
        "reason" => attrs["reason"] || opt(opts, :reason),
        "evidence" => attrs["evidence"] || opt(opts, :evidence, []),
        "proposed_at" => DateTime.to_iso8601(now())
      }
      |> compact_map()
      |> Map.merge(attrs["provenance"] || %{})

    attrs
    |> Map.merge(%{
      "workspace_id" => agent.workspace_id,
      "created_by_agent_id" => agent.id,
      "type_key" => "memory",
      "status" => "draft",
      "confidence" => Map.get(attrs, "confidence", 0.4),
      "importance" => Map.get(attrs, "importance", 0.5),
      "attributes" => attributes,
      "provenance" => provenance
    })
    |> Knowledge.create_node()
  end

  def propose_from_run(%Run{} = run) do
    run = Repo.preload(run, [:steps, :supervisor_agent])

    cond do
      is_nil(run.supervisor_agent) ->
        {:error, %{"reason" => "missing_supervisor_agent", "run_id" => run.id}}

      true ->
        case get_run_detail_proposal(run) do
          %Node{} = proposal ->
            {:ok, proposal}

          nil ->
            propose_node(run.supervisor_agent, %{
              title: proposal_title(run),
              body: proposal_body(run),
              run_id: run.id,
              reason: "Proposed from run detail",
              evidence: proposal_evidence(run),
              confidence: 0.55,
              importance: 0.65,
              provenance: %{
                "source" => "run_detail",
                "source_run_title" => run.title
              }
            })
        end
    end
  end

  def list_proposals(workspace_id, opts \\ []) do
    proposal_status = opt(opts, :proposal_status) || "pending"

    workspace_id
    |> Knowledge.list_nodes(type_key: "memory", limit: opt(opts, :limit, 100))
    |> Enum.filter(&proposal_node?/1)
    |> Enum.filter(fn node ->
      proposal_status in [nil, "all"] or node.attributes["proposal_status"] == proposal_status
    end)
  end

  def promote_proposal(id_or_node, attrs \\ %{}) do
    id_or_node
    |> proposal_node()
    |> update_proposal("promoted", "active", attrs)
  end

  def reject_proposal(id_or_node, attrs \\ %{}) do
    id_or_node
    |> proposal_node()
    |> update_proposal("rejected", "archived", attrs)
  end

  def update_proposal_draft(id_or_node, attrs \\ %{}) do
    node = proposal_node(id_or_node)
    attrs = stringify_keys(attrs)

    cond do
      not proposal_node?(node) ->
        {:error, %{"reason" => "not_memory_proposal", "node_id" => node.id}}

      (node.attributes || %{})["proposal_status"] != "pending" ->
        {:error,
         %{
           "reason" => "proposal_already_reviewed",
           "node_id" => node.id,
           "proposal_status" => (node.attributes || %{})["proposal_status"]
         }}

      true ->
        Knowledge.update_node(node, %{
          title: Map.get(attrs, "title", node.title),
          body: Map.get(attrs, "body", node.body),
          confidence: parse_score(attrs["confidence"], node.confidence),
          importance: parse_score(attrs["importance"], node.importance),
          attributes:
            (node.attributes || %{})
            |> Map.merge(%{
              "edited_at" => DateTime.to_iso8601(now()),
              "edited_actor" => attrs["actor"] || "operator"
            })
        })
    end
  end

  def update_memory_node(id_or_node, attrs \\ %{}) do
    node = proposal_node(id_or_node)
    attrs = stringify_keys(attrs)

    cond do
      node.type_key != "memory" ->
        {:error, %{"reason" => "not_memory_node", "node_id" => node.id}}

      proposal_node?(node) and (node.attributes || %{})["proposal_status"] == "pending" ->
        {:error, %{"reason" => "pending_proposal_requires_review", "node_id" => node.id}}

      true ->
        Knowledge.update_node(node, %{
          status: Map.get(attrs, "status", node.status),
          confidence: parse_score(attrs["confidence"], node.confidence),
          importance: parse_score(attrs["importance"], node.importance),
          attributes:
            (node.attributes || %{})
            |> Map.merge(%{
              "edited_at" => DateTime.to_iso8601(now()),
              "edited_actor" => attrs["actor"] || "operator"
            })
        })
    end
  end

  def archive_node(id_or_node, attrs \\ %{}) do
    node = proposal_node(id_or_node)
    attrs = stringify_keys(attrs)

    cond do
      node.type_key != "memory" ->
        {:error, %{"reason" => "not_memory_node", "node_id" => node.id}}

      proposal_node?(node) and (node.attributes || %{})["proposal_status"] == "pending" ->
        {:error, %{"reason" => "pending_proposal_requires_review", "node_id" => node.id}}

      true ->
        Knowledge.update_node(node, %{
          status: "archived",
          attributes:
            (node.attributes || %{})
            |> Map.merge(%{
              "archived_at" => DateTime.to_iso8601(now()),
              "archived_actor" => attrs["actor"] || "operator",
              "archived_reason" => attrs["reason"] || "operator_archive"
            })
        })
    end
  end

  def format_context(%{"nodes" => []}), do: ""

  def format_context(%{"nodes" => nodes}) do
    nodes
    |> Enum.map_join("\n", fn node ->
      "- [#{node["type_key"]}:#{node["id"]}] #{node["title"]}: #{node["body"]}"
    end)
  end

  def curate_workspace(workspace_id, opts \\ []) do
    archive_below = opt(opts, :archive_below_confidence, 0.2)
    dry_run? = opt(opts, :dry_run?, true)
    archive_low_confidence? = opt(opts, :archive_low_confidence?, not dry_run?)
    resolve_duplicates? = opt(opts, :resolve_duplicates?, false)
    actor = opt(opts, :actor, "curator")
    archived_at = DateTime.to_iso8601(now())

    low_confidence =
      workspace_id
      |> Knowledge.list_nodes(status: "active", limit: 500)
      |> Enum.filter(&(&1.confidence < archive_below))

    duplicates = duplicate_memory_title_groups(workspace_id)

    archived_low_confidence =
      if dry_run? or not archive_low_confidence? do
        []
      else
        Enum.map(low_confidence, fn node ->
          {:ok, updated} =
            Knowledge.update_node(node, %{
              status: "archived",
              attributes:
                Map.merge(node.attributes || %{}, %{
                  "archived_at" => archived_at,
                  "archived_actor" => actor,
                  "archived_reason" => "low_confidence",
                  "archive_below_confidence" => archive_below
                })
            })

          updated
        end)
      end

    archived_duplicates =
      if dry_run? or not resolve_duplicates? do
        []
      else
        duplicates
        |> Enum.flat_map(&archive_duplicate_group(&1, actor, archived_at))
      end

    %{
      "dry_run" => dry_run?,
      "archive_below_confidence" => archive_below,
      "low_confidence_candidates" => Enum.map(low_confidence, &node_context/1),
      "archived_node_ids" => Enum.map(archived_low_confidence, & &1.id),
      "archived_duplicate_node_ids" => Enum.map(archived_duplicates, & &1.id),
      "duplicate_title_groups" => Enum.map(duplicates, &duplicate_group_context/1)
    }
  end

  defp in_scope?(node, %AgentProfile{} = agent) do
    scopes = agent.knowledge_scopes || []
    "workspace" in scopes or node.type_key in scopes
  end

  defp recallable?(node), do: node.status in ["active", "verified"]

  defp proposal_node(%Node{} = node), do: node
  defp proposal_node(id), do: Knowledge.get_node!(id)

  defp update_proposal(%Node{} = node, decision, status, attrs) do
    attrs = stringify_keys(attrs)

    cond do
      not proposal_node?(node) ->
        {:error, %{"reason" => "not_memory_proposal", "node_id" => node.id}}

      (node.attributes || %{})["proposal_status"] != "pending" ->
        {:error,
         %{
           "reason" => "proposal_already_reviewed",
           "node_id" => node.id,
           "proposal_status" => (node.attributes || %{})["proposal_status"]
         }}

      true ->
        review = review_metadata(decision, attrs)

        Knowledge.update_node(node, %{
          status: status,
          attributes:
            (node.attributes || %{})
            |> Map.merge(%{"proposal_status" => decision})
            |> Map.merge(Map.take(review, ["reviewed_at", "review_actor", "review_reason"])),
          provenance: append_review(node.provenance || %{}, review)
        })
    end
  end

  defp proposal_node?(%Node{} = node) do
    node.type_key == "memory" and node.provenance["kind"] == "memory_proposal"
  end

  defp proposal_node?(_node), do: false

  defp get_run_detail_proposal(run) do
    run.workspace_id
    |> list_proposals(proposal_status: "all", limit: 500)
    |> Enum.find(fn node ->
      node.provenance["run_id"] == run.id and node.provenance["source"] == "run_detail"
    end)
  end

  defp proposal_title(run) do
    run.title
    |> to_string()
    |> String.trim()
    |> case do
      "" -> "Memory from run #{run.id}"
      title -> String.slice("Memory from #{title}", 0, 160)
    end
  end

  defp proposal_body(run) do
    steps =
      run.steps
      |> Enum.map(fn step -> "- #{step.title}: #{step.status}" end)
      |> case do
        [] -> "- No run steps were captured."
        lines -> Enum.join(lines, "\n")
      end

    [
      "Source run: #{run.title}",
      "Goal: #{run.goal}",
      "",
      "Observed steps:",
      steps
    ]
    |> Enum.join("\n")
  end

  defp proposal_evidence(run) do
    run.steps
    |> Enum.map(& &1.title)
    |> Enum.reject(&is_nil/1)
    |> Enum.take(8)
  end

  defp parse_score(nil, fallback), do: fallback
  defp parse_score(value, _fallback) when is_float(value), do: value
  defp parse_score(value, _fallback) when is_integer(value), do: value / 1

  defp parse_score(value, fallback) when is_binary(value) do
    case Float.parse(value) do
      {number, ""} -> number
      _error -> fallback
    end
  end

  defp parse_score(_value, fallback), do: fallback

  defp review_metadata(decision, attrs) do
    %{
      "decision" => decision,
      "review_actor" => attrs["actor"] || "operator",
      "review_reason" => attrs["reason"],
      "reviewed_at" => DateTime.to_iso8601(now())
    }
    |> compact_map()
  end

  defp append_review(provenance, review) do
    Map.update(provenance, "reviews", [review], fn reviews ->
      if is_list(reviews), do: reviews ++ [review], else: [review]
    end)
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

  defp duplicate_memory_title_groups(workspace_id) do
    workspace_id
    |> Knowledge.list_nodes(type_key: "memory", limit: 500)
    |> Enum.filter(&(&1.status in ["active", "verified"]))
    |> Enum.group_by(&normalize_title(&1.title))
    |> Enum.reject(fn {title, nodes} -> title == "" or length(nodes) < 2 end)
    |> Enum.map(fn {title, nodes} ->
      sorted = Enum.sort_by(nodes, &duplicate_rank/1, :desc)
      %{title: title, canonical: hd(sorted), duplicates: tl(sorted)}
    end)
  end

  defp duplicate_rank(node) do
    {
      if(node.status == "verified", do: 1, else: 0),
      node.confidence || 0.0,
      node.importance || 0.0,
      node.id || 0
    }
  end

  defp archive_duplicate_group(
         %{canonical: canonical, duplicates: duplicates},
         actor,
         archived_at
       ) do
    Enum.map(duplicates, fn node ->
      {:ok, updated} =
        Knowledge.update_node(node, %{
          status: "archived",
          attributes:
            Map.merge(node.attributes || %{}, %{
              "archived_at" => archived_at,
              "archived_actor" => actor,
              "archived_reason" => "duplicate_title",
              "duplicate_canonical_node_id" => canonical.id
            })
        })

      updated
    end)
  end

  defp duplicate_group_context(%{title: title, canonical: canonical, duplicates: duplicates}) do
    %{
      "title" => title,
      "count" => length(duplicates) + 1,
      "canonical_node" => node_context(canonical),
      "duplicate_nodes" => Enum.map(duplicates, &node_context/1)
    }
  end

  defp normalize_title(title) do
    title
    |> to_string()
    |> String.trim()
    |> String.downcase()
  end

  defp compact_map(map) do
    Map.reject(map, fn {_key, value} -> is_nil(value) or value == "" or value == [] end)
  end

  defp stringify_keys(map) when is_map(map) do
    Map.new(map, fn {key, value} -> {to_string(key), value} end)
  end

  defp opt(opts, key, default \\ nil)
  defp opt(opts, key, default) when is_list(opts), do: Keyword.get(opts, key, default)

  defp opt(opts, key, default) when is_map(opts),
    do: Map.get(opts, key) || Map.get(opts, to_string(key), default)

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:microsecond)
end
