defmodule HydraAgentWeb.ToolController do
  use HydraAgentWeb, :controller

  alias HydraAgent.Tools.Registry

  def index(conn, %{"workspace_id" => workspace_id}) do
    json(conn, %{data: Registry.all(workspace_id)})
  end

  def index(conn, _params) do
    json(conn, %{data: Registry.all()})
  end

  def bundles(conn, %{"workspace_id" => workspace_id}) do
    json(conn, %{data: HydraAgent.Tools.Bundles.all(workspace_id)})
  end

  def bundles(conn, _params) do
    json(conn, %{data: HydraAgent.Tools.Bundles.all()})
  end
end
