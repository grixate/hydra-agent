defmodule HydraAgent.Repo.Migrations.ConstrainSimLabRunCosts do
  use Ecto.Migration

  def change do
    create constraint(:sim_lab_runs, :sim_lab_runs_non_negative_costs,
             check:
               "(budget_cap_usd IS NULL OR budget_cap_usd >= 0) AND (actual_cost_usd IS NULL OR actual_cost_usd >= 0)"
           )
  end
end
