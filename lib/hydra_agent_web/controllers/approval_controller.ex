defmodule HydraAgentWeb.ApprovalController do
  use HydraAgentWeb, :controller

  alias HydraAgent.Runtime

  def index(conn, %{"workspace_id" => workspace_id}) do
    steps = Runtime.list_awaiting_approval_steps(workspace_id)
    json(conn, %{data: Enum.map(steps, &step_json/1)})
  end

  defp step_json(step) do
    %{
      id: step.id,
      run_id: step.run_id,
      run: run_json(step.run),
      assigned_agent_id: step.assigned_agent_id,
      assigned_agent: agent_json(step.assigned_agent),
      index: step.index,
      title: step.title,
      tool_name: step.tool_name,
      side_effect_class: step.side_effect_class,
      input: step.input,
      approval: step.approval,
      inserted_at: step.inserted_at
    }
  end

  defp run_json(%Ecto.Association.NotLoaded{}), do: nil
  defp run_json(nil), do: nil

  defp run_json(run) do
    %{
      id: run.id,
      title: run.title,
      goal: run.goal,
      status: run.status,
      autonomy_level: run.autonomy_level
    }
  end

  defp agent_json(%Ecto.Association.NotLoaded{}), do: nil
  defp agent_json(nil), do: nil

  defp agent_json(agent) do
    %{
      id: agent.id,
      name: agent.name,
      slug: agent.slug,
      role: agent.role
    }
  end
end
