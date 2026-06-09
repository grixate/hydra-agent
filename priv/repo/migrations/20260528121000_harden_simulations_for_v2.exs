defmodule HydraAgent.Repo.Migrations.HardenSimulationsForV2 do
  use Ecto.Migration

  def change do
    alter table(:simulations) do
      add :lease_id, :string
      add :lease_owner, :string
      add :lease_expires_at, :utc_datetime_usec
      add :last_heartbeat_at, :utc_datetime_usec
      add :recovery_count, :integer, null: false, default: 0
    end

    create index(:simulations, [:status, :lease_expires_at])
    create index(:simulations, [:lease_id])

    create table(:simulation_budget_reservations) do
      add :workspace_id, references(:workspaces, on_delete: :delete_all), null: false
      add :simulation_id, references(:simulations, on_delete: :delete_all), null: false
      add :agent_id, references(:agent_profiles, on_delete: :nilify_all)
      add :category, :string, null: false, default: "simulation"
      add :estimated_tokens, :integer, null: false, default: 0
      add :estimated_cost_cents, :integer, null: false, default: 0
      add :reserved_cost_cents, :integer, null: false, default: 0
      add :spent_cost_cents, :integer, null: false, default: 0
      add :status, :string, null: false, default: "active"
      add :metadata, :map, null: false, default: %{}

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:simulation_budget_reservations, [:simulation_id])
    create index(:simulation_budget_reservations, [:workspace_id, :category, :status])
    create index(:simulation_budget_reservations, [:agent_id])
  end
end
