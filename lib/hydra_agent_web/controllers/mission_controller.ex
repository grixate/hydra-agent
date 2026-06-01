defmodule HydraAgentWeb.MissionController do
  use HydraAgentWeb, :controller

  alias HydraAgent.Runtime

  def index(conn, %{"workspace_id" => workspace_id} = params) do
    missions = Runtime.list_missions(workspace_id, params)
    json(conn, %{data: Enum.map(missions, &mission_json/1)})
  end

  def create(conn, %{"workspace_id" => workspace_id} = params) do
    do_create(conn, Map.put(params, "workspace_id", workspace_id))
  end

  def create(conn, params) do
    do_create(conn, params)
  end

  defp do_create(conn, params) do
    case Runtime.create_mission(params) do
      {:ok, mission} ->
        conn
        |> put_status(:created)
        |> json(%{data: mission_json(mission)})

      {:error, changeset} ->
        changeset_error(conn, changeset)
    end
  end

  def show(conn, %{"workspace_id" => workspace_id, "id" => id}) do
    mission = Runtime.get_mission_for_workspace!(workspace_id, id)
    json(conn, %{data: mission_json(mission)})
  end

  def show(conn, %{"id" => id}) do
    mission = Runtime.get_mission!(id)
    json(conn, %{data: mission_json(mission)})
  end

  def update(conn, %{"workspace_id" => workspace_id, "id" => id} = params) do
    mission = Runtime.get_mission_for_workspace!(workspace_id, id)

    case Runtime.update_mission(mission, params) do
      {:ok, mission} -> json(conn, %{data: mission_json(mission)})
      {:error, changeset} -> changeset_error(conn, changeset)
    end
  end

  def update(conn, %{"id" => id} = params) do
    mission = Runtime.get_mission!(id)

    case Runtime.update_mission(mission, params) do
      {:ok, mission} -> json(conn, %{data: mission_json(mission)})
      {:error, changeset} -> changeset_error(conn, changeset)
    end
  end

  def start(conn, %{"workspace_id" => workspace_id, "id" => id} = params) do
    mission = Runtime.get_mission_for_workspace!(workspace_id, id)

    case Runtime.start_mission(mission, params) do
      {:ok, %{mission: mission, run: run}} ->
        json(conn, %{data: %{mission: mission_json(mission), run: run_json(run)}})

      {:error, changeset} ->
        changeset_error(conn, changeset)
    end
  end

  def start(conn, %{"id" => id} = params) do
    mission = Runtime.get_mission!(id)

    case Runtime.start_mission(mission, params) do
      {:ok, %{mission: mission, run: run}} ->
        json(conn, %{data: %{mission: mission_json(mission), run: run_json(run)}})

      {:error, changeset} ->
        changeset_error(conn, changeset)
    end
  end

  defp mission_json(mission) do
    %{
      id: mission.id,
      workspace_id: mission.workspace_id,
      supervisor_agent_id: mission.supervisor_agent_id,
      title: mission.title,
      slug: mission.slug,
      objective: mission.objective,
      mission_type: mission.mission_type,
      status: mission.status,
      priority: mission.priority,
      deadline_at: mission.deadline_at,
      success_criteria: mission.success_criteria,
      context: mission.context,
      team: mission.team,
      permissions: mission.permissions,
      budget: mission.budget,
      start_mode: mission.start_mode,
      metadata: mission.metadata,
      started_at: mission.started_at,
      completed_at: mission.completed_at,
      runs: Enum.map((Ecto.assoc_loaded?(mission.runs) && mission.runs) || [], &run_json/1)
    }
  end

  defp run_json(run) do
    %{
      id: run.id,
      mission_id: run.mission_id,
      parent_run_id: run.parent_run_id,
      lineage_type: run.lineage_type,
      title: run.title,
      goal: run.goal,
      status: run.status,
      priority: run.priority,
      autonomy_level: run.autonomy_level
    }
  end

  defp changeset_error(conn, changeset) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{errors: errors_json(changeset)})
  end

  defp errors_json(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
      Enum.reduce(opts, message, fn {key, value}, acc ->
        String.replace(acc, "%{#{key}}", to_string(value))
      end)
    end)
  end
end
