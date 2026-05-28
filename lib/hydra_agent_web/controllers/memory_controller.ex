defmodule HydraAgentWeb.MemoryController do
  use HydraAgentWeb, :controller

  alias HydraAgent.Memory
  alias HydraAgent.Runtime

  def proposals(conn, %{"workspace_id" => workspace_id} = params) do
    proposals =
      Memory.list_proposals(workspace_id,
        proposal_status: params["proposal_status"],
        limit: parse_int(params["limit"], 100)
      )

    json(conn, %{data: Enum.map(proposals, &node_json/1)})
  end

  def curate(conn, %{"workspace_id" => workspace_id} = params) do
    result =
      Memory.curate_workspace(workspace_id,
        dry_run?: params["dry_run"] != false,
        archive_below_confidence: parse_float(params["archive_below_confidence"], 0.2)
      )

    json(conn, %{data: result})
  end

  def propose(conn, %{"id" => agent_id} = params) do
    agent = Runtime.get_agent!(agent_id)

    case Memory.propose_node(agent, params) do
      {:ok, node} ->
        conn
        |> put_status(:created)
        |> json(%{data: node_json(node)})

      {:error, changeset} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{errors: errors_json(changeset)})
    end
  end

  def promote_proposal(conn, %{"id" => id} = params) do
    render_proposal_result(conn, Memory.promote_proposal(id, params))
  end

  def reject_proposal(conn, %{"id" => id} = params) do
    render_proposal_result(conn, Memory.reject_proposal(id, params))
  end

  defp node_json(node) do
    %{
      id: node.id,
      workspace_id: node.workspace_id,
      type_key: node.type_key,
      title: node.title,
      body: node.body,
      status: node.status,
      attributes: node.attributes,
      importance: node.importance,
      confidence: node.confidence,
      provenance: node.provenance,
      created_by_agent_id: node.created_by_agent_id
    }
  end

  defp parse_float(nil, default), do: default
  defp parse_float(value, _default) when is_float(value), do: value
  defp parse_float(value, _default) when is_integer(value), do: value / 1

  defp parse_float(value, default) when is_binary(value) do
    case Float.parse(value) do
      {float, _rest} -> float
      :error -> default
    end
  end

  defp parse_int(nil, default), do: default
  defp parse_int(value, _default) when is_integer(value), do: value

  defp parse_int(value, default) when is_binary(value) do
    case Integer.parse(value) do
      {integer, ""} -> integer
      _parsed -> default
    end
  end

  defp render_proposal_result(conn, {:ok, node}), do: json(conn, %{data: node_json(node)})

  defp render_proposal_result(conn, {:error, %{} = error}) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{errors: error})
  end

  defp errors_json(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
      Enum.reduce(opts, message, fn {key, value}, acc ->
        String.replace(acc, "%{#{key}}", to_string(value))
      end)
    end)
  end
end
