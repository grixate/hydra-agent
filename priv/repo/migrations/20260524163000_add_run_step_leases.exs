defmodule HydraAgent.Repo.Migrations.AddRunStepLeases do
  use Ecto.Migration

  def change do
    alter table(:run_steps) do
      add :attempt_count, :integer, null: false, default: 0
      add :lease_owner, :string
      add :lease_expires_at, :utc_datetime_usec
      add :heartbeat_at, :utc_datetime_usec
    end

    create index(:run_steps, [:status, :lease_expires_at])
    create index(:run_steps, [:lease_owner])
  end
end
