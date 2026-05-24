defmodule HydraAgentWeb.UsageController do
  use HydraAgentWeb, :controller

  alias HydraAgent.Usage

  def index(conn, %{"workspace_id" => workspace_id} = params) do
    records = Usage.list_records(workspace_id, category: params["category"])
    json(conn, %{data: Enum.map(records, &record_json/1), summary: Usage.summarize(workspace_id)})
  end

  defp record_json(record) do
    %{
      id: record.id,
      workspace_id: record.workspace_id,
      agent_id: record.agent_id,
      run_id: record.run_id,
      run_step_id: record.run_step_id,
      conversation_id: record.conversation_id,
      turn_id: record.turn_id,
      provider: record.provider,
      model: record.model,
      category: record.category,
      status: record.status,
      input_tokens: record.input_tokens,
      output_tokens: record.output_tokens,
      total_tokens: record.total_tokens,
      estimated_cost: record.estimated_cost,
      latency_ms: record.latency_ms,
      metadata: record.metadata,
      inserted_at: record.inserted_at
    }
  end
end
