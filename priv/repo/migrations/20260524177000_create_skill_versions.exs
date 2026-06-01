defmodule HydraAgent.Repo.Migrations.CreateSkillVersions do
  use Ecto.Migration

  def change do
    create table(:skill_versions) do
      add :workspace_id, references(:workspaces, on_delete: :delete_all), null: false
      add :skill_id, references(:skills, on_delete: :delete_all), null: false
      add :version, :integer, null: false
      add :change_kind, :string, null: false
      add :status, :string, null: false
      add :snapshot, :map, null: false, default: %{}
      add :metadata, :map, null: false, default: %{}

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:skill_versions, [:skill_id, :version])
    create index(:skill_versions, [:workspace_id])
    create index(:skill_versions, [:skill_id])

    execute(
      """
      INSERT INTO skill_versions (
        workspace_id,
        skill_id,
        version,
        change_kind,
        status,
        snapshot,
        metadata,
        inserted_at,
        updated_at
      )
      SELECT
        workspace_id,
        id,
        1,
        'created',
        status,
        jsonb_build_object(
          'name', name,
          'slug', slug,
          'description', description,
          'status', status,
          'instructions', instructions,
          'trigger_conditions', trigger_conditions,
          'required_tools', required_tools,
          'memory_scopes', memory_scopes,
          'knowledge_scopes', knowledge_scopes,
          'evals', evals,
          'provenance', provenance,
          'owner_agent_id', owner_agent_id,
          'source_run_id', source_run_id,
          'activated_at', activated_at,
          'deprecated_at', deprecated_at
        ),
        jsonb_build_object('backfilled', true),
        inserted_at,
        updated_at
      FROM skills
      """,
      """
      DELETE FROM skill_versions
      WHERE metadata ->> 'backfilled' = 'true'
      """
    )
  end
end
