defmodule HydraAgentWeb.ToolController do
  use HydraAgentWeb, :controller

  alias HydraAgent.Tools.Registry

  def index(conn, _params) do
    json(conn, %{data: Registry.all()})
  end
end
