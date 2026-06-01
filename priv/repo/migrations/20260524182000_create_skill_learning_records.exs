defmodule HydraAgent.Repo.Migrations.CreateSkillLearningRecords do
  use Ecto.Migration

  def change do
    create table(:skill_usage_events) do
      add :workspace_id, references(:workspaces, on_delete: :delete_all), null: false
      add :skill_id, references(:skills, on_delete: :nilify_all)
      add :agent_id, references(:agent_profiles, on_delete: :nilify_all)
      add :run_id, references(:runs, on_delete: :nilify_all)
      add :conversation_id, references(:conversations, on_delete: :nilify_all)
      add :room_id, references(:agent_rooms, on_delete: :nilify_all)
      add :trigger_text, :text
      add :match_score, :float, null: false, default: 0.0
      add :outcome_status, :string, null: false, default: "observed"
      add :tool_count, :integer, null: false, default: 0
      add :error_summary, :text
      add :metadata, :map, null: false, default: %{}

      timestamps(type: :utc_datetime_usec)
    end

    create index(:skill_usage_events, [:workspace_id, :skill_id])
    create index(:skill_usage_events, [:workspace_id, :run_id])
    create index(:skill_usage_events, [:workspace_id, :outcome_status])

    create table(:skill_improvement_proposals) do
      add :workspace_id, references(:workspaces, on_delete: :delete_all), null: false
      add :target_skill_id, references(:skills, on_delete: :nilify_all)
      add :source_run_id, references(:runs, on_delete: :nilify_all)
      add :source_conversation_id, references(:conversations, on_delete: :nilify_all)
      add :source_room_id, references(:agent_rooms, on_delete: :nilify_all)
      add :kind, :string, null: false
      add :status, :string, null: false, default: "draft"
      add :proposed_snapshot, :map, null: false, default: %{}
      add :evaluation_report, :map, null: false, default: %{}
      add :confidence, :float, null: false, default: 0.0
      add :metadata, :map, null: false, default: %{}

      timestamps(type: :utc_datetime_usec)
    end

    create index(:skill_improvement_proposals, [:workspace_id, :status])
    create index(:skill_improvement_proposals, [:workspace_id, :kind])
    create index(:skill_improvement_proposals, [:target_skill_id])
    create index(:skill_improvement_proposals, [:source_run_id])
  end
end
