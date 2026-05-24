defmodule HydraAgent.Runtime.AgentMatcher do
  @moduledoc """
  Capability-based worker selection for planner-produced steps.

  LLM planners may provide an explicit `assigned_agent_id`, but the runtime
  should not require perfect IDs in generated plans. The matcher scores active
  agents by declared tools, side-effect classes, role, and skills so unassigned
  steps can still be delegated transparently.
  """

  alias HydraAgent.Runtime.AgentProfile

  def assign_step(step, agents) when is_map(step) and is_list(agents) do
    if present?(step["assigned_agent_id"] || step[:assigned_agent_id]) do
      step
    else
      case best_agent(agents, step) do
        %AgentProfile{id: id} when not is_nil(id) -> Map.put(step, "assigned_agent_id", id)
        _agent -> step
      end
    end
  end

  def best_agent(agents, step) when is_list(agents) and is_map(step) do
    agents
    |> Enum.filter(&(&1.status == "active"))
    |> Enum.map(&{score_agent(&1, step), &1})
    |> Enum.filter(fn {score, _agent} -> score > 0 end)
    |> Enum.sort_by(fn {score, agent} -> {-score, agent.name || ""} end)
    |> List.first()
    |> case do
      {_score, agent} -> agent
      nil -> nil
    end
  end

  defp score_agent(%AgentProfile{} = agent, step) do
    capability_profile = agent.capability_profile || %{}
    tool_name = step["tool_name"] || step[:tool_name]
    side_effect_class = step["side_effect_class"] || step[:side_effect_class] || "read_only"
    requested_role = step["role"] || step[:role]
    requested_skills = List.wrap(step["skills"] || step[:skills] || [])

    0
    |> add_if(tool_name in List.wrap(capability_profile["tools"]), 100)
    |> add_if(side_effect_class in List.wrap(capability_profile["side_effect_classes"]), 30)
    |> add_if(not is_nil(requested_role) and requested_role == agent.role, 20)
    |> Kernel.+(skill_score(requested_skills, List.wrap(capability_profile["skills"])))
  end

  defp skill_score([], _agent_skills), do: 0

  defp skill_score(requested_skills, agent_skills) do
    requested_skills
    |> Enum.count(&(&1 in agent_skills))
    |> Kernel.*(5)
  end

  defp add_if(score, true, points), do: score + points
  defp add_if(score, false, _points), do: score

  defp present?(nil), do: false
  defp present?(""), do: false
  defp present?(_value), do: true
end
