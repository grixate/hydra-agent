defmodule HydraAgent.Tools.SimulationCancel do
  @behaviour HydraAgent.Tool

  alias HydraAgent.Simulation

  @impl true
  def spec do
    %{
      name: "simulation_cancel",
      side_effect_class: "workspace_write",
      timeout_ms: 10_000,
      approval_sensitive: true,
      description: "Cancel an existing workspace simulation.",
      input_schema: %{"type" => "object", "required" => ["simulation_id"]},
      output_schema: %{"type" => "object"}
    }
  end

  @impl true
  def execute(input, context) do
    with {:ok, simulation} <- fetch(input, context),
         {:ok, canceled} <- Simulation.cancel_simulation(simulation) do
      {:ok, %{"simulation" => Simulation.simulation_json(canceled)}}
    else
      {:error, error} -> {:error, normalize_error(error)}
    end
  end

  defp fetch(input, context) do
    input = stringify_keys(input || %{})
    workspace_id = context["workspace_id"] || context[:workspace_id]

    with {:ok, id} <- required_id(input["simulation_id"]) do
      Simulation.fetch_simulation_for_workspace(workspace_id, id)
    end
  end

  defp required_id(nil), do: {:error, %{"reason" => "simulation_id_required"}}
  defp required_id(id), do: {:ok, id}
  defp stringify_keys(map), do: Map.new(map, fn {key, value} -> {to_string(key), value} end)
  defp normalize_error(error) when is_map(error), do: error
  defp normalize_error(error), do: %{"reason" => inspect(error)}
end
