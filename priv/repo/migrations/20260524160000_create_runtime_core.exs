defmodule HydraAgent.Repo.Migrations.CreateRuntimeCore do
  use Ecto.Migration

  def change do
    create table(:workspaces) do
      add :name, :string, null: false
      add :slug, :string, null: false
      add :description, :text
      add :status, :string, null: false, default: "active"
      add :settings, :map, null: false, default: %{}

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:workspaces, [:slug])

    create table(:agent_profiles) do
      add :workspace_id, references(:workspaces, on_delete: :delete_all), null: false
      add :name, :string, null: false
      add :slug, :string, null: false
      add :role, :string, null: false, default: "operator"
      add :status, :string, null: false, default: "active"
      add :description, :text
      add :system_prompt, :text
      add :model_route, :map, null: false, default: %{}
      add :capability_profile, :map, null: false, default: %{}
      add :memory_scopes, {:array, :string}, null: false, default: []
      add :knowledge_scopes, {:array, :string}, null: false, default: []
      add :runtime_state, :map, null: false, default: %{}

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:agent_profiles, [:workspace_id, :slug])
    create index(:agent_profiles, [:workspace_id, :role])

    create table(:provider_configs) do
      add :workspace_id, references(:workspaces, on_delete: :delete_all)
      add :name, :string, null: false
      add :kind, :string, null: false, default: "openai_compatible"
      add :base_url, :text
      add :model, :string, null: false
      add :api_key_env, :string
      add :enabled, :boolean, null: false, default: true
      add :metadata, :map, null: false, default: %{}

      timestamps(type: :utc_datetime_usec)
    end

    create index(:provider_configs, [:workspace_id, :enabled])

    create table(:tool_policies) do
      add :workspace_id, references(:workspaces, on_delete: :delete_all), null: false
      add :agent_id, references(:agent_profiles, on_delete: :delete_all)
      add :scope, :string, null: false, default: "agent"
      add :allowed_tools, {:array, :string}, null: false, default: []
      add :side_effect_classes, {:array, :string}, null: false, default: ["read_only"]
      add :network_allowlist, {:array, :string}, null: false, default: []
      add :shell_allowlist, {:array, :string}, null: false, default: []
      add :requires_approval, :boolean, null: false, default: true
      add :metadata, :map, null: false, default: %{}

      timestamps(type: :utc_datetime_usec)
    end

    create index(:tool_policies, [:workspace_id, :agent_id])

    create table(:runs) do
      add :workspace_id, references(:workspaces, on_delete: :delete_all), null: false
      add :supervisor_agent_id, references(:agent_profiles, on_delete: :nilify_all)
      add :title, :string, null: false
      add :goal, :text, null: false
      add :status, :string, null: false, default: "planned"
      add :autonomy_level, :string, null: false, default: "recommend"
      add :priority, :integer, null: false, default: 0
      add :budget, :map, null: false, default: %{}
      add :plan, :map, null: false, default: %{}
      add :result, :map, null: false, default: %{}
      add :runtime_state, :map, null: false, default: %{}
      add :metadata, :map, null: false, default: %{}
      add :started_at, :utc_datetime_usec
      add :completed_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create index(:runs, [:workspace_id, :status])

    create table(:run_steps) do
      add :run_id, references(:runs, on_delete: :delete_all), null: false
      add :assigned_agent_id, references(:agent_profiles, on_delete: :nilify_all)
      add :index, :integer, null: false
      add :title, :string, null: false
      add :status, :string, null: false, default: "planned"
      add :tool_name, :string
      add :side_effect_class, :string, null: false, default: "read_only"
      add :input, :map, null: false, default: %{}
      add :output, :map, null: false, default: %{}
      add :approval, :map, null: false, default: %{}
      add :error, :map, null: false, default: %{}
      add :started_at, :utc_datetime_usec
      add :completed_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:run_steps, [:run_id, :index])
    create index(:run_steps, [:assigned_agent_id, :status])

    create table(:conversations) do
      add :workspace_id, references(:workspaces, on_delete: :delete_all), null: false
      add :agent_id, references(:agent_profiles, on_delete: :delete_all), null: false
      add :title, :string
      add :channel, :string, null: false, default: "control_plane"
      add :status, :string, null: false, default: "active"
      add :metadata, :map, null: false, default: %{}
      add :last_message_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create index(:conversations, [:workspace_id, :agent_id])
    create index(:conversations, [:workspace_id, :status])

    create table(:turns) do
      add :conversation_id, references(:conversations, on_delete: :delete_all), null: false
      add :run_id, references(:runs, on_delete: :nilify_all)
      add :role, :string, null: false
      add :kind, :string, null: false, default: "message"
      add :content, :text, null: false
      add :metadata, :map, null: false, default: %{}

      timestamps(type: :utc_datetime_usec)
    end

    create index(:turns, [:conversation_id, :inserted_at])
    create index(:turns, [:run_id])
  end
end
