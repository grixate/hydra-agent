defmodule HydraAgent.Repo.Migrations.CreateSkills do
  use Ecto.Migration

  def change do
    create table(:skills) do
      add :workspace_id, references(:workspaces, on_delete: :delete_all), null: false
      add :owner_agent_id, references(:agent_profiles, on_delete: :nilify_all)
      add :source_run_id, references(:runs, on_delete: :nilify_all)
      add :name, :string, null: false
      add :slug, :string, null: false
      add :description, :text, null: false
      add :status, :string, null: false, default: "proposed"
      add :instructions, :text, null: false
      add :trigger_conditions, :map, null: false, default: %{}
      add :required_tools, {:array, :string}, null: false, default: []
      add :memory_scopes, {:array, :string}, null: false, default: []
      add :knowledge_scopes, {:array, :string}, null: false, default: []
      add :evals, :map, null: false, default: %{}
      add :provenance, :map, null: false, default: %{}
      add :activated_at, :utc_datetime_usec
      add :deprecated_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:skills, [:workspace_id, :slug])
    create index(:skills, [:workspace_id, :status])
    create index(:skills, [:owner_agent_id])
    create index(:skills, [:source_run_id])
  end
end
