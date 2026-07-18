defmodule HydraAgent.Repo.Migrations.AddExecutionOptionsToSimLabRuns do
  use Ecto.Migration

  def change do
    alter table(:sim_lab_runs) do
      add :execution_options, :map, null: false, default: %{}
    end
  end
end
