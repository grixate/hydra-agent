defmodule HydraAgent.Repo.Migrations.CreateBudgets do
  use Ecto.Migration

  def change do
    create table(:budgets) do
      add :workspace_id, references(:workspaces, on_delete: :delete_all), null: false
      add :agent_id, references(:agent_profiles, on_delete: :delete_all)
      add :name, :string, null: false
      add :status, :string, null: false, default: "active"
      add :category, :string
      add :period, :string, null: false, default: "monthly"
      add :token_limit, :integer
      add :cost_limit, :decimal, precision: 12, scale: 4
      add :metadata, :map, null: false, default: %{}

      timestamps(type: :utc_datetime_usec)
    end

    create index(:budgets, [:workspace_id])
    create index(:budgets, [:agent_id])
    create index(:budgets, [:status])
  end
end
