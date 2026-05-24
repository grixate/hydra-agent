defmodule HydraAgentWeb.SkillController do
  use HydraAgentWeb, :controller

  alias HydraAgent.Skills

  def index(conn, %{"workspace_id" => workspace_id} = params) do
    skills = Skills.list_skills(workspace_id, status: params["status"])
    json(conn, %{data: Enum.map(skills, &skill_json/1)})
  end

  def show(conn, %{"id" => id}) do
    skill = Skills.get_skill!(id)
    json(conn, %{data: skill_json(skill)})
  end

  def create(conn, params) do
    case Skills.create_skill(params) do
      {:ok, skill} ->
        conn
        |> put_status(:created)
        |> json(%{data: skill_json(skill)})

      {:error, changeset} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{errors: errors_json(changeset)})
    end
  end

  def activate(conn, %{"id" => id} = params) do
    skill = Skills.get_skill!(id)
    render_result(conn, Skills.activate_skill(skill, params))
  end

  def test(conn, %{"id" => id} = params) do
    skill = Skills.get_skill!(id)
    render_result(conn, Skills.test_skill(skill, params))
  end

  def deprecate(conn, %{"id" => id} = params) do
    skill = Skills.get_skill!(id)
    render_result(conn, Skills.deprecate_skill(skill, params))
  end

  def archive(conn, %{"id" => id} = params) do
    skill = Skills.get_skill!(id)
    render_result(conn, Skills.archive_skill(skill, params))
  end

  defp render_result(conn, {:ok, skill}), do: json(conn, %{data: skill_json(skill)})

  defp render_result(conn, {:error, changeset}) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{errors: errors_json(changeset)})
  end

  defp skill_json(skill) do
    %{
      id: skill.id,
      workspace_id: skill.workspace_id,
      owner_agent_id: skill.owner_agent_id,
      source_run_id: skill.source_run_id,
      name: skill.name,
      slug: skill.slug,
      description: skill.description,
      status: skill.status,
      instructions: skill.instructions,
      trigger_conditions: skill.trigger_conditions,
      required_tools: skill.required_tools,
      memory_scopes: skill.memory_scopes,
      knowledge_scopes: skill.knowledge_scopes,
      evals: skill.evals,
      provenance: skill.provenance,
      activated_at: skill.activated_at,
      deprecated_at: skill.deprecated_at
    }
  end

  defp errors_json(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
      Enum.reduce(opts, message, fn {key, value}, acc ->
        String.replace(acc, "%{#{key}}", to_string(value))
      end)
    end)
  end
end
