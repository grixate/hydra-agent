defmodule HydraAgentWeb.AuditController do
  use HydraAgentWeb, :controller

  alias HydraAgent.Audit

  def export(conn, %{"workspace_id" => workspace_id}) do
    json(conn, %{data: Audit.export_workspace(workspace_id)})
  end
end
