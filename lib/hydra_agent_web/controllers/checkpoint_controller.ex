defmodule HydraAgentWeb.CheckpointController do
  use HydraAgentWeb, :controller

  alias HydraAgent.Tools.Checkpoints

  def index(conn, %{"workspace_id" => workspace_id} = params) do
    checkpoints = Checkpoints.list_records(workspace_id, params)
    json(conn, %{data: Enum.map(checkpoints, &checkpoint_json/1)})
  end

  def diff(conn, %{"workspace_id" => workspace_id, "id" => id} = params) do
    case Checkpoints.diff_record_for_workspace(workspace_id, id, params) do
      {:ok, diff} -> json(conn, %{data: diff})
      {:error, error} -> conn |> put_status(:unprocessable_entity) |> json(%{errors: error})
    end
  end

  def diff(conn, %{"id" => id} = params) do
    case Checkpoints.diff_record(id, params) do
      {:ok, diff} -> json(conn, %{data: diff})
      {:error, error} -> conn |> put_status(:unprocessable_entity) |> json(%{errors: error})
    end
  end

  def restore(conn, %{"workspace_id" => workspace_id, "id" => id} = params) do
    case Checkpoints.restore_record_for_workspace(workspace_id, id, params) do
      {:ok, restored} -> json(conn, %{data: restored})
      {:error, error} -> conn |> put_status(:unprocessable_entity) |> json(%{errors: error})
    end
  end

  def restore(conn, %{"id" => id} = params) do
    case Checkpoints.restore_record(id, params) do
      {:ok, restored} -> json(conn, %{data: restored})
      {:error, error} -> conn |> put_status(:unprocessable_entity) |> json(%{errors: error})
    end
  end

  defp checkpoint_json(checkpoint) do
    %{
      id: checkpoint.id,
      workspace_id: checkpoint.workspace_id,
      run_id: checkpoint.run_id,
      run_step_id: checkpoint.run_step_id,
      tool_name: checkpoint.tool_name,
      path: checkpoint.path,
      relative_path: checkpoint.relative_path,
      checkpoint_path: checkpoint.checkpoint_path,
      sha256: checkpoint.sha256,
      existed: checkpoint.existed,
      restored_at: checkpoint.restored_at,
      metadata: checkpoint.metadata,
      inserted_at: checkpoint.inserted_at
    }
  end
end
