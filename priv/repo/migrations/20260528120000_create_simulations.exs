defmodule HydraAgent.Repo.Migrations.CreateSimulations do
  use Ecto.Migration

  def change do
    create table(:simulations) do
      add :workspace_id, references(:workspaces, on_delete: :delete_all), null: false
      add :supervisor_agent_id, references(:agent_profiles, on_delete: :nilify_all)
      add :run_id, references(:runs, on_delete: :nilify_all)
      add :title, :string, null: false
      add :goal, :text, null: false
      add :status, :string, null: false, default: "configuring"
      add :config, :map, null: false, default: %{}
      add :seed_material, :text
      add :world_snapshot, :map, null: false, default: %{}
      add :budget_plan, :map, null: false, default: %{}
      add :budget_usage, :map, null: false, default: %{}
      add :total_ticks, :integer, null: false, default: 0
      add :total_llm_calls, :integer, null: false, default: 0
      add :total_tokens_used, :integer, null: false, default: 0
      add :total_cost_cents, :integer, null: false, default: 0
      add :started_at, :utc_datetime_usec
      add :completed_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create index(:simulations, [:workspace_id, :status])
    create index(:simulations, [:supervisor_agent_id])
    create index(:simulations, [:run_id])

    create table(:simulation_agent_profiles) do
      add :simulation_id, references(:simulations, on_delete: :delete_all), null: false
      add :agent_key, :string, null: false
      add :persona, :map, null: false, default: %{}
      add :initial_beliefs, :map, null: false, default: %{}
      add :initial_relationships, :map, null: false, default: %{}
      add :final_state, :map, null: false, default: %{}

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:simulation_agent_profiles, [:simulation_id, :agent_key])

    create table(:simulation_ticks) do
      add :simulation_id, references(:simulations, on_delete: :delete_all), null: false
      add :tick_number, :integer, null: false
      add :duration_us, :integer, null: false, default: 0
      add :tier_counts, :map, null: false, default: %{}
      add :llm_calls, :integer, null: false, default: 0
      add :tokens_used, :integer, null: false, default: 0
      add :cost_cents, :integer, null: false, default: 0
      add :world_delta, :map, null: false, default: %{}

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:simulation_ticks, [:simulation_id, :tick_number])

    create table(:simulation_events) do
      add :simulation_id, references(:simulations, on_delete: :delete_all), null: false
      add :tick, :integer, null: false
      add :event_type, :string, null: false
      add :source, :string
      add :target, :string
      add :description, :text
      add :properties, :map, null: false, default: %{}
      add :stakes, :float

      timestamps(type: :utc_datetime_usec)
    end

    create index(:simulation_events, [:simulation_id, :tick])

    create table(:simulation_reports) do
      add :simulation_id, references(:simulations, on_delete: :delete_all), null: false
      add :content, :text, null: false
      add :statistical_summary, :map, null: false, default: %{}
      add :generated_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create index(:simulation_reports, [:simulation_id])
  end
end
