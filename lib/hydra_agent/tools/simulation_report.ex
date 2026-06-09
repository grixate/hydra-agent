defmodule HydraAgent.Tools.SimulationReport do
  @behaviour HydraAgent.Tool

  alias HydraAgent.Simulation

  @impl true
  def spec do
    %{
      name: "simulation_report",
      side_effect_class: "workspace_write",
      timeout_ms: 10_000,
      approval_sensitive: true,
      description: "Generate an inspectable Markdown report for a completed simulation.",
      input_schema: %{"type" => "object", "required" => ["simulation_id"]},
      output_schema: %{"type" => "object"}
    }
  end

  @impl true
  def execute(input, context) do
    input = stringify_keys(input || %{})
    workspace_id = context["workspace_id"] || context[:workspace_id]

    with {:ok, id} <- required_id(input["simulation_id"]),
         {:ok, simulation} <- Simulation.fetch_simulation_for_workspace(workspace_id, id),
         {:ok, report} <- Simulation.generate_report(simulation) do
      {:ok,
       %{
         "report" => %{
           "id" => report.id,
           "simulation_id" => report.simulation_id,
           "content" => report.content,
           "summary" => report.statistical_summary
         }
       }}
    else
      {:error, error} -> {:error, normalize_error(error)}
    end
  end

  defp required_id(nil), do: {:error, %{"reason" => "simulation_id_required"}}
  defp required_id(id), do: {:ok, id}

  defp stringify_keys(map), do: Map.new(map, fn {key, value} -> {to_string(key), value} end)

  defp normalize_error(%Ecto.Changeset{} = changeset),
    do: %{"reason" => inspect(changeset.errors)}

  defp normalize_error(error) when is_map(error), do: error
  defp normalize_error(error), do: %{"reason" => inspect(error)}
end
