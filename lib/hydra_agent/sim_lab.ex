defmodule HydraAgent.SimLab do
  @moduledoc """
  The optional Synthetic Research Lab product boundary.

  The first release keeps simulation deterministic and external research
  provider-neutral. It exposes a durable, provenance-aware product boundary
  without coupling the core agent runtime to a research workflow.
  """

  alias HydraAgent.SimLab.{
    Calibrations,
    Costing,
    Demo,
    Jobs,
    SimulationInput,
    SimulationRunner,
    Simulations,
    Simulator,
    Studies
  }

  alias HydraAgent.SimLab.Research.{
    MockWebSearchProvider,
    Runner,
    StudyParser,
    WebResearchPlanner
  }

  def demo_study, do: Demo.study()
  def demo_run, do: Simulator.run(Demo.simulation_input())
  def cost_preview(mode), do: Costing.estimate(mode)
  def list_studies(workspace_id), do: Studies.list_studies(workspace_id)
  def create_study(attrs), do: Studies.create_study(attrs)

  def plan_research(question, attrs \\ %{}, opts \\ %{}) do
    question |> StudyParser.parse(attrs) |> WebResearchPlanner.plan(opts)
  end

  def run_research(question, attrs \\ %{}, opts \\ %{}) do
    Runner.run(question, attrs, MockWebSearchProvider, opts)
  end

  def prepare_simulation(input, study, opts \\ %{}),
    do: SimulationRunner.prepare(input, study, opts)

  def start_research(study, question, attrs \\ %{}, opts \\ %{}),
    do: Jobs.start_research(study, question, attrs, opts)

  def start_simulation(study, scenario, context_pack, input, opts \\ %{}),
    do: Simulations.queue_run(study, scenario, context_pack, input, opts)

  def build_simulation_input(personas, patterns, scenario, opts \\ %{}),
    do: SimulationInput.build(personas, patterns, scenario, opts)

  def record_calibration(study, run, attrs), do: Calibrations.record(study, run, attrs)
  def generate_behavior_draft(study), do: Studies.generate_behavior_draft(study)

  def generate_scenario_draft(study, context_pack),
    do: Simulations.generate_scenario_draft(study, context_pack)
end
