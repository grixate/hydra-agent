defmodule HydraAgent.Repo.Migrations.AllowDirectContextSources do
  use Ecto.Migration

  def up do
    drop constraint(
           :simulation_context_research_runs,
           :simulation_context_research_runs_provider_check
         )

    create constraint(
             :simulation_context_research_runs,
             :simulation_context_research_runs_provider_check,
             check: "provider IN ('web_search','direct_sources','mock')"
           )
  end

  def down do
    drop constraint(
           :simulation_context_research_runs,
           :simulation_context_research_runs_provider_check
         )

    create constraint(
             :simulation_context_research_runs,
             :simulation_context_research_runs_provider_check,
             check: "provider IN ('web_search','mock')"
           )
  end
end
