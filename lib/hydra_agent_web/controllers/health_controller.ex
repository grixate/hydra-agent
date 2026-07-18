defmodule HydraAgentWeb.HealthController do
  use HydraAgentWeb, :controller

  alias HydraAgent.Repo
  alias HydraAgentWeb.TelemetryReporter

  def show(conn, _params) do
    json(conn, %{
      data: %{
        service: "hydra-agent",
        status: "ok",
        runtime: %{
          workspaces: "enabled",
          agents: "enabled",
          runs: "enabled",
          knowledge_graph: "enabled",
          tool_policy: "least_privilege"
        }
      }
    })
  end

  def live(conn, _params), do: json(conn, %{status: "ok"})

  def ready(conn, _params) do
    checks = %{
      database: database_ready?(),
      migrations: migrations_current?(),
      jobs: jobs_ready?()
    }

    if Enum.all?(checks, fn {_name, ready?} -> ready? end) do
      json(conn, %{status: "ready", checks: checks})
    else
      conn |> put_status(:service_unavailable) |> json(%{status: "not_ready", checks: checks})
    end
  end

  def metrics(conn, _params), do: json(conn, %{data: TelemetryReporter.snapshot()})

  def openmetrics(conn, _params) do
    conn
    |> put_resp_content_type("application/openmetrics-text", "utf-8")
    |> send_resp(:ok, TelemetryReporter.openmetrics())
  end

  defp database_ready? do
    match?({:ok, _result}, Ecto.Adapters.SQL.query(Repo, "SELECT 1", []))
  rescue
    _ -> false
  end

  defp jobs_ready? do
    HydraAgent.Supervisor
    |> Supervisor.which_children()
    |> Enum.any?(fn
      {Oban, pid, :supervisor, _modules} when is_pid(pid) -> Process.alive?(pid)
      _ -> false
    end)
  rescue
    _ -> false
  end

  defp migrations_current? do
    Ecto.Migrator.migrations(Repo)
    |> Enum.all?(fn {status, _version, _name} -> status == :up end)
  rescue
    _ -> false
  end
end
