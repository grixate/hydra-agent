defmodule HydraAgent.Repo.Migrations.TightenScriptPreviewAgentBound do
  use Ecto.Migration

  def up do
    drop constraint(:simulation_script_previews, :simulation_script_previews_bounds_check)

    create constraint(:simulation_script_previews, :simulation_script_previews_bounds_check,
             check:
               "rounds_requested BETWEEN 1 AND 2 AND rounds_completed BETWEEN 0 AND rounds_requested AND agent_count BETWEEN 0 AND 12 AND seed >= 0"
           )
  end

  def down do
    drop constraint(:simulation_script_previews, :simulation_script_previews_bounds_check)

    create constraint(:simulation_script_previews, :simulation_script_previews_bounds_check,
             check:
               "rounds_requested BETWEEN 1 AND 2 AND rounds_completed BETWEEN 0 AND rounds_requested AND agent_count BETWEEN 0 AND 32 AND seed >= 0"
           )
  end
end
