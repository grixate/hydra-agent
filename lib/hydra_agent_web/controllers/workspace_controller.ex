defmodule HydraAgentWeb.WorkspaceController do
  use HydraAgentWeb, :controller

  alias HydraAgent.Runtime

  def index(conn, _params) do
    json(conn, %{data: Enum.map(Runtime.list_workspaces(), &workspace_json/1)})
  end

  def create(conn, params) do
    case Runtime.create_workspace(params) do
      {:ok, workspace} ->
        conn
        |> put_status(:created)
        |> json(%{data: workspace_json(workspace)})

      {:error, changeset} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{errors: errors_json(changeset)})
    end
  end

  def show(conn, %{"id" => id}) do
    json(conn, %{data: workspace_json(Runtime.get_workspace!(id))})
  end

  defp workspace_json(workspace) do
    %{
      id: workspace.id,
      name: workspace.name,
      slug: workspace.slug,
      description: workspace.description,
      status: workspace.status,
      settings: workspace.settings
    }
  end

  defp errors_json(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
      Enum.reduce(opts, message, fn {key, value}, acc ->
        String.replace(acc, "%{#{key}}", to_string(value))
      end)
    end)
  end
end
