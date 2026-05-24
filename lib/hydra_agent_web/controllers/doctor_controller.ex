defmodule HydraAgentWeb.DoctorController do
  use HydraAgentWeb, :controller

  alias HydraAgent.Doctor

  def show(conn, params) do
    opts =
      case params do
        %{"workspace_id" => workspace_id} -> [workspace_id: workspace_id]
        _params -> []
      end

    report = Doctor.run(opts)
    status = if report["status"] == "error", do: :service_unavailable, else: :ok

    conn
    |> put_status(status)
    |> json(%{data: report})
  end
end
