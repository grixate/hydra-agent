defmodule HydraAgentWeb.SafetyController do
  use HydraAgentWeb, :controller

  alias HydraAgent.Safety

  def index(conn, %{"workspace_id" => workspace_id} = params) do
    events =
      Safety.list_events(workspace_id,
        category: params["category"]
      )

    json(conn, %{data: Enum.map(events, &event_json/1)})
  end

  defp event_json(event) do
    %{
      id: event.id,
      workspace_id: event.workspace_id,
      agent_id: event.agent_id,
      run_id: event.run_id,
      run_step_id: event.run_step_id,
      category: event.category,
      severity: event.severity,
      action: event.action,
      summary: event.summary,
      metadata: event.metadata,
      acknowledged_at: event.acknowledged_at,
      inserted_at: event.inserted_at
    }
  end
end
