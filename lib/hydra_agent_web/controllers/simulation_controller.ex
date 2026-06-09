defmodule HydraAgentWeb.SimulationController do
  use HydraAgentWeb, :controller

  alias HydraAgent.Simulation

  def index(conn, %{"workspace_id" => workspace_id} = params) do
    simulations = Simulation.list_simulations(workspace_id, params)
    json(conn, %{data: Enum.map(simulations, &Simulation.simulation_json/1)})
  end

  def create(conn, %{"workspace_id" => workspace_id} = params) do
    attrs = Map.put(params, "workspace_id", workspace_id)

    case Simulation.create_simulation(attrs) do
      {:ok, simulation} ->
        conn
        |> put_status(:created)
        |> json(%{data: Simulation.simulation_json(simulation)})

      {:error, %Ecto.Changeset{} = changeset} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{errors: errors_json(changeset)})

      {:error, error} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{errors: error})
    end
  end

  def show(conn, %{"workspace_id" => workspace_id, "id" => id}) do
    simulation = Simulation.get_simulation_for_workspace!(workspace_id, id)
    json(conn, %{data: Simulation.simulation_json(simulation)})
  end

  def estimate(conn, params) do
    json(conn, %{data: Simulation.estimate(params)})
  end

  def start(conn, %{"workspace_id" => workspace_id, "id" => id}) do
    simulation = Simulation.get_simulation_for_workspace!(workspace_id, id)
    render_transition(conn, Simulation.start_simulation(simulation))
  end

  def pause(conn, %{"workspace_id" => workspace_id, "id" => id}) do
    simulation = Simulation.get_simulation_for_workspace!(workspace_id, id)
    render_transition(conn, Simulation.pause_simulation(simulation))
  end

  def resume(conn, %{"workspace_id" => workspace_id, "id" => id}) do
    simulation = Simulation.get_simulation_for_workspace!(workspace_id, id)
    render_transition(conn, Simulation.resume_simulation(simulation))
  end

  def cancel(conn, %{"workspace_id" => workspace_id, "id" => id}) do
    simulation = Simulation.get_simulation_for_workspace!(workspace_id, id)
    render_transition(conn, Simulation.cancel_simulation(simulation))
  end

  def report(conn, %{"workspace_id" => workspace_id, "id" => id}) do
    simulation = Simulation.get_simulation_for_workspace!(workspace_id, id)

    case Simulation.generate_report(simulation) do
      {:ok, report} ->
        json(conn, %{
          data: %{id: report.id, content: report.content, summary: report.statistical_summary}
        })

      {:error, %Ecto.Changeset{} = changeset} ->
        conn |> put_status(:unprocessable_entity) |> json(%{errors: errors_json(changeset)})

      {:error, error} ->
        conn |> put_status(:conflict) |> json(%{errors: error})
    end
  end

  def replay(conn, %{"workspace_id" => workspace_id, "id" => id}) do
    simulation = Simulation.get_simulation_for_workspace!(workspace_id, id)
    json(conn, %{data: Simulation.replay(simulation, conn.params)})
  end

  def export(conn, %{"workspace_id" => workspace_id, "id" => id}) do
    simulation = Simulation.get_simulation_for_workspace!(workspace_id, id)
    json(conn, %{data: Simulation.export(simulation)})
  end

  def duplicate(conn, %{"workspace_id" => workspace_id, "id" => id} = params) do
    simulation = Simulation.get_simulation_for_workspace!(workspace_id, id)

    case Simulation.duplicate_simulation(simulation, params) do
      {:ok, simulation} ->
        conn
        |> put_status(:created)
        |> json(%{data: Simulation.simulation_json(simulation)})

      {:error, %Ecto.Changeset{} = changeset} ->
        conn |> put_status(:unprocessable_entity) |> json(%{errors: errors_json(changeset)})

      {:error, error} ->
        conn |> put_status(:conflict) |> json(%{errors: error})
    end
  end

  defp render_transition(conn, {:ok, simulation}) do
    json(conn, %{data: Simulation.simulation_json(simulation)})
  end

  defp render_transition(conn, {:error, %Ecto.Changeset{} = changeset}) do
    conn |> put_status(:unprocessable_entity) |> json(%{errors: errors_json(changeset)})
  end

  defp render_transition(conn, {:error, error}) do
    conn |> put_status(:conflict) |> json(%{errors: error})
  end

  defp errors_json(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
      Enum.reduce(opts, message, fn {key, value}, acc ->
        String.replace(acc, "%{#{key}}", to_string(value))
      end)
    end)
  end
end
