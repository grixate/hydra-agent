defmodule HydraAgentWeb.HealthController do
  use HydraAgentWeb, :controller

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
end
