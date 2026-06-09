defmodule HydraAgent.Tools.SimulationEstimate do
  @behaviour HydraAgent.Tool

  alias HydraAgent.Simulation

  @impl true
  def spec do
    %{
      name: "simulation_estimate",
      side_effect_class: "read_only",
      timeout_ms: 5_000,
      approval_sensitive: false,
      description: "Estimate token and cost budget for a neutral simulation config.",
      input_schema: %{"type" => "object"},
      output_schema: %{"type" => "object"}
    }
  end

  @impl true
  def execute(input, _context), do: {:ok, Simulation.estimate(input || %{})}
end
