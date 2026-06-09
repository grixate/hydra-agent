defmodule HydraAgent.Tools.SimulationCreate do
  @behaviour HydraAgent.Tool

  alias HydraAgent.Simulation

  @impl true
  def spec do
    %{
      name: "simulation_create",
      side_effect_class: "workspace_write",
      timeout_ms: 10_000,
      approval_sensitive: true,
      description: "Create a workspace-scoped neutral simulation with a hard budget cap.",
      input_schema: %{"type" => "object", "required" => ["title", "goal"]},
      output_schema: %{"type" => "object"}
    }
  end

  @impl true
  def execute(input, context) do
    input = stringify_keys(input || %{})
    workspace_id = context["workspace_id"] || context[:workspace_id]
    agent_id = context["agent_id"] || context[:agent_id]
    run_id = context["run_id"] || context[:run_id]

    attrs =
      input
      |> Map.put("workspace_id", workspace_id)
      |> Map.put_new("supervisor_agent_id", agent_id)
      |> Map.put_new("run_id", run_id)

    case Simulation.create_simulation(attrs) do
      {:ok, simulation} -> {:ok, %{"simulation" => Simulation.simulation_json(simulation)}}
      {:error, error} -> {:error, normalize_error(error)}
    end
  end

  defp stringify_keys(map), do: Map.new(map, fn {key, value} -> {to_string(key), value} end)

  defp normalize_error(%Ecto.Changeset{} = changeset),
    do: %{"reason" => inspect(changeset.errors)}

  defp normalize_error(error) when is_map(error), do: error
  defp normalize_error(error), do: %{"reason" => inspect(error)}
end
