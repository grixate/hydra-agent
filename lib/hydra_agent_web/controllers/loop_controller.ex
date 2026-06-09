defmodule HydraAgentWeb.LoopController do
  use HydraAgentWeb, :controller

  alias HydraAgent.Loops
  alias HydraAgent.Loops.Engine

  def index(conn, %{"workspace_id" => workspace_id} = params) do
    loops = Loops.list_loops(workspace_id, status: params["status"], q: params["q"])
    json(conn, %{data: Enum.map(loops, &loop_json/1)})
  end

  def recipes(conn, _params) do
    json(conn, %{data: Loops.recipes()})
  end

  def create_from_recipe(
        conn,
        %{"workspace_id" => workspace_id, "recipe_id" => recipe_id} = params
      ) do
    case Loops.create_from_recipe(workspace_id, recipe_id, params) do
      {:ok, loop} ->
        conn |> put_status(:created) |> json(%{data: loop_json(loop)})

      {:error, %Ecto.Changeset{} = changeset} ->
        conn |> put_status(:unprocessable_entity) |> json(%{errors: errors_json(changeset)})

      {:error, error} ->
        conn |> put_status(:unprocessable_entity) |> json(%{errors: error})
    end
  end

  def show(conn, %{"workspace_id" => workspace_id, "id" => id}) do
    loop = Loops.get_loop_for_workspace!(workspace_id, id)
    json(conn, %{data: loop_json(loop)})
  end

  def create(conn, %{"workspace_id" => workspace_id} = params) do
    case Loops.create_loop(Map.put(params, "workspace_id", workspace_id)) do
      {:ok, loop} ->
        conn |> put_status(:created) |> json(%{data: loop_json(loop)})

      {:error, changeset} ->
        conn |> put_status(:unprocessable_entity) |> json(%{errors: errors_json(changeset)})
    end
  end

  def update(conn, %{"workspace_id" => workspace_id, "id" => id} = params) do
    loop = Loops.get_loop_for_workspace!(workspace_id, id)

    case Loops.update_loop(loop, params) do
      {:ok, loop} ->
        json(conn, %{data: loop_json(loop)})

      {:error, changeset} ->
        conn |> put_status(:unprocessable_entity) |> json(%{errors: errors_json(changeset)})
    end
  end

  def trigger(conn, %{"workspace_id" => workspace_id, "id" => id}) do
    loop = Loops.get_loop_for_workspace!(workspace_id, id)

    case Engine.tick(loop, lease_owner: "api-loop-trigger") do
      {:ok, result} ->
        json(conn, %{data: tick_json(result)})

      {:error, error} ->
        conn |> put_status(:unprocessable_entity) |> json(%{errors: error})
    end
  end

  def pause(conn, %{"workspace_id" => workspace_id, "id" => id}) do
    loop = Loops.get_loop_for_workspace!(workspace_id, id)

    case Loops.pause_loop(loop) do
      {:ok, loop} ->
        json(conn, %{data: loop_json(loop)})

      {:error, changeset} ->
        conn |> put_status(:unprocessable_entity) |> json(%{errors: errors_json(changeset)})
    end
  end

  def resume(conn, %{"workspace_id" => workspace_id, "id" => id}) do
    loop = Loops.get_loop_for_workspace!(workspace_id, id)

    case Loops.resume_loop(loop) do
      {:ok, loop} ->
        json(conn, %{data: loop_json(loop)})

      {:error, changeset} ->
        conn |> put_status(:unprocessable_entity) |> json(%{errors: errors_json(changeset)})
    end
  end

  def archive(conn, %{"workspace_id" => workspace_id, "id" => id}) do
    loop = Loops.get_loop_for_workspace!(workspace_id, id)

    case Loops.archive_loop(loop) do
      {:ok, loop} ->
        json(conn, %{data: loop_json(loop)})

      {:error, changeset} ->
        conn |> put_status(:unprocessable_entity) |> json(%{errors: errors_json(changeset)})
    end
  end

  defp loop_json(loop) do
    %{
      id: loop.id,
      workspace_id: loop.workspace_id,
      mission_id: loop.mission_id,
      supervisor_agent_id: loop.supervisor_agent_id,
      verifier_agent_id: loop.verifier_agent_id,
      name: loop.name,
      slug: loop.slug,
      status: loop.status,
      purpose: loop.purpose,
      trigger: loop.trigger,
      body: loop.body,
      autonomy_level: loop.autonomy_level,
      budget: loop.budget,
      guardrails: loop.guardrails,
      state: loop.state,
      last_error: loop.last_error,
      next_tick_at: loop.next_tick_at,
      last_tick_at: loop.last_tick_at,
      lease_owner: loop.lease_owner,
      lease_expires_at: loop.lease_expires_at,
      metadata: loop.metadata,
      mission: assoc_json(loop, :mission, &mission_json/1),
      supervisor_agent: assoc_json(loop, :supervisor_agent, &agent_json/1),
      verifier_agent: assoc_json(loop, :verifier_agent, &agent_json/1),
      runs: Enum.map(loaded(loop.runs), &run_json/1)
    }
  end

  defp tick_json(result) do
    %{
      loop: loop_json(result.loop),
      run: run_json(result.run),
      decision: result.decision,
      verification: result.verification,
      stop_reason: result.stop_reason,
      child_runs: Enum.map(result.child_runs, &run_json/1)
    }
  end

  defp mission_json(mission), do: %{id: mission.id, title: mission.title, status: mission.status}

  defp agent_json(agent),
    do: %{id: agent.id, name: agent.name, slug: agent.slug, role: agent.role}

  defp run_json(run) do
    %{
      id: run.id,
      mission_id: run.mission_id,
      loop_id: run.loop_id,
      parent_run_id: run.parent_run_id,
      title: run.title,
      goal: run.goal,
      status: run.status,
      lineage_type: run.lineage_type,
      metadata: run.metadata
    }
  end

  defp assoc_json(parent, assoc, mapper) do
    value = Map.get(parent, assoc)
    if Ecto.assoc_loaded?(value) and value, do: mapper.(value), else: nil
  end

  defp loaded(value), do: if(Ecto.assoc_loaded?(value), do: value, else: [])

  defp errors_json(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
      Enum.reduce(opts, message, fn {key, value}, acc ->
        String.replace(acc, "%{#{key}}", to_string(value))
      end)
    end)
  end
end
