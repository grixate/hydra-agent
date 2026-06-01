defmodule HydraAgent.Repo.Migrations.CreateSkillImports do
  use Ecto.Migration

  def change do
    create table(:skill_imports) do
      add :workspace_id, references(:workspaces, on_delete: :delete_all), null: false
      add :installed_skill_id, references(:skills, on_delete: :nilify_all)
      add :source_type, :string, null: false
      add :source_url, :string
      add :source_path, :string
      add :source_ref, :string
      add :status, :string, null: false, default: "scanned"
      add :skill_attrs, :map, null: false, default: %{}
      add :file_manifest, {:array, :map}, null: false, default: []
      add :scan_result, :map, null: false, default: %{}
      add :warnings, {:array, :map}, null: false, default: []
      add :approved_by, :string
      add :approved_at, :utc_datetime_usec
      add :metadata, :map, null: false, default: %{}

      timestamps(type: :utc_datetime_usec)
    end

    create index(:skill_imports, [:workspace_id, :status])
    create index(:skill_imports, [:workspace_id, :source_type])
    create index(:skill_imports, [:installed_skill_id])
  end
end
