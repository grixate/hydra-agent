defmodule HydraAgent.Repo.Migrations.CreateKnowledgeGraph do
  use Ecto.Migration

  def change do
    create table(:knowledge_type_definitions) do
      add :workspace_id, references(:workspaces, on_delete: :delete_all), null: false
      add :kind, :string, null: false
      add :type_key, :string, null: false
      add :display_name, :string, null: false
      add :description, :text
      add :extends, :string
      add :attribute_schema, :map, null: false, default: %{}
      add :status_vocabulary, {:array, :string}, null: false, default: []
      add :metadata, :map, null: false, default: %{}

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:knowledge_type_definitions, [:workspace_id, :kind, :type_key])

    create table(:knowledge_nodes) do
      add :workspace_id, references(:workspaces, on_delete: :delete_all), null: false
      add :created_by_agent_id, references(:agent_profiles, on_delete: :nilify_all)
      add :type_key, :string, null: false
      add :title, :string, null: false
      add :body, :text
      add :status, :string, null: false, default: "active"
      add :attributes, :map, null: false, default: %{}
      add :importance, :float, null: false, default: 0.5
      add :confidence, :float, null: false, default: 0.5
      add :provenance, :map, null: false, default: %{}
      add :created_by_operator, :boolean, null: false, default: false

      timestamps(type: :utc_datetime_usec)
    end

    create index(:knowledge_nodes, [:workspace_id, :type_key])
    create index(:knowledge_nodes, [:workspace_id, :status])

    create table(:knowledge_relationships) do
      add :workspace_id, references(:workspaces, on_delete: :delete_all), null: false
      add :from_node_id, references(:knowledge_nodes, on_delete: :delete_all), null: false
      add :to_node_id, references(:knowledge_nodes, on_delete: :delete_all), null: false
      add :created_by_agent_id, references(:agent_profiles, on_delete: :nilify_all)
      add :type_key, :string, null: false
      add :attributes, :map, null: false, default: %{}
      add :confidence, :float, null: false, default: 0.5
      add :provenance, :map, null: false, default: %{}

      timestamps(type: :utc_datetime_usec)
    end

    create index(:knowledge_relationships, [:workspace_id, :type_key])
    create index(:knowledge_relationships, [:from_node_id])
    create index(:knowledge_relationships, [:to_node_id])
  end
end
