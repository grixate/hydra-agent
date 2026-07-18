defmodule HydraAgent.Repo.Migrations.AddInputProvenanceToSimLabRuns do
  use Ecto.Migration

  def change do
    alter table(:sim_lab_runs) do
      add :input_snapshot, :map, null: false, default: %{}
      add :input_fingerprint, :string
    end

    create index(:sim_lab_runs, [:input_fingerprint])
  end
end
