defmodule HydraAgent.Repo.Migrations.CreateEvals do
  use Ecto.Migration

  def change do
    create table(:eval_suites) do
      add :workspace_id, references(:workspaces, on_delete: :delete_all), null: false
      add :name, :string, null: false
      add :slug, :string, null: false
      add :description, :text
      add :status, :string, null: false, default: "active"
      add :metadata, :map, null: false, default: %{}

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:eval_suites, [:workspace_id, :slug])
    create index(:eval_suites, [:workspace_id, :status])

    create table(:eval_cases) do
      add :workspace_id, references(:workspaces, on_delete: :delete_all), null: false
      add :suite_id, references(:eval_suites, on_delete: :delete_all), null: false
      add :name, :string, null: false
      add :slug, :string, null: false
      add :prompt, :text, null: false
      add :expected, :map, null: false, default: %{}
      add :scoring, :map, null: false, default: %{}
      add :metadata, :map, null: false, default: %{}

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:eval_cases, [:suite_id, :slug])
    create index(:eval_cases, [:workspace_id])

    create table(:eval_runs) do
      add :workspace_id, references(:workspaces, on_delete: :delete_all), null: false
      add :suite_id, references(:eval_suites, on_delete: :delete_all), null: false
      add :agent_id, references(:agent_profiles, on_delete: :nilify_all)
      add :status, :string, null: false, default: "planned"
      add :summary, :map, null: false, default: %{}
      add :started_at, :utc_datetime_usec
      add :completed_at, :utc_datetime_usec
      add :metadata, :map, null: false, default: %{}

      timestamps(type: :utc_datetime_usec)
    end

    create index(:eval_runs, [:workspace_id, :status])
    create index(:eval_runs, [:suite_id])

    create table(:eval_results) do
      add :workspace_id, references(:workspaces, on_delete: :delete_all), null: false
      add :eval_run_id, references(:eval_runs, on_delete: :delete_all), null: false
      add :eval_case_id, references(:eval_cases, on_delete: :delete_all), null: false
      add :status, :string, null: false, default: "pending"
      add :score, :float
      add :output, :map, null: false, default: %{}
      add :error, :map, null: false, default: %{}
      add :metadata, :map, null: false, default: %{}

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:eval_results, [:eval_run_id, :eval_case_id])
    create index(:eval_results, [:workspace_id, :status])
  end
end
