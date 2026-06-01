defmodule HydraAgent.Repo.Migrations.CreateSkillExperiments do
  use Ecto.Migration

  def change do
    create table(:skill_experiments) do
      add :workspace_id, references(:workspaces, on_delete: :delete_all), null: false
      add :skill_id, references(:skills, on_delete: :delete_all), null: false
      add :source_conversation_id, references(:conversations, on_delete: :nilify_all)
      add :source_room_id, references(:agent_rooms, on_delete: :nilify_all)
      add :selected_proposal_id, references(:skill_improvement_proposals, on_delete: :nilify_all)
      add :status, :string, null: false, default: "planned"
      add :candidate_snapshots, :map, null: false, default: %{}
      add :evaluation_report, :map, null: false, default: %{}
      add :winner_snapshot, :map, null: false, default: %{}
      add :metadata, :map, null: false, default: %{}

      timestamps(type: :utc_datetime_usec)
    end

    create index(:skill_experiments, [:workspace_id, :status])
    create index(:skill_experiments, [:skill_id, :status])
  end
end
