defmodule HydraAgentWeb.AgentBuilderController do
  use HydraAgentWeb, :controller

  alias HydraAgent.AgentBuilder

  def preview(conn, %{"workspace_id" => workspace_id} = params) do
    json(conn, %{data: AgentBuilder.preview(workspace_id, params)})
  end

  def create(conn, %{"workspace_id" => workspace_id} = params) do
    case AgentBuilder.create(workspace_id, params) do
      {:ok, result} ->
        conn
        |> put_status(:created)
        |> json(%{
          data: %{
            agent: agent_json(result.agent),
            policy: policy_json(result.policy),
            preview: result.preview
          }
        })

      {:error, error} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{errors: errors_json(error)})
    end
  end

  defp agent_json(agent) do
    %{
      id: agent.id,
      workspace_id: agent.workspace_id,
      name: agent.name,
      slug: agent.slug,
      role: agent.role,
      status: agent.status,
      description: agent.description,
      model_route: agent.model_route,
      capability_profile: agent.capability_profile,
      memory_scopes: agent.memory_scopes,
      knowledge_scopes: agent.knowledge_scopes
    }
  end

  defp policy_json(policy) do
    %{
      id: policy.id,
      workspace_id: policy.workspace_id,
      agent_id: policy.agent_id,
      allowed_tools: policy.allowed_tools,
      side_effect_classes: policy.side_effect_classes,
      requires_approval: policy.requires_approval,
      metadata: policy.metadata
    }
  end

  defp errors_json(%Ecto.Changeset{} = changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
      Enum.reduce(opts, message, fn {key, value}, acc ->
        String.replace(acc, "%{#{key}}", to_string(value))
      end)
    end)
  end

  defp errors_json(error) when is_map(error), do: error
  defp errors_json(error), do: %{detail: inspect(error)}
end
