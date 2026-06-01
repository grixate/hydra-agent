defmodule HydraAgent.Repo.Migrations.CreateAgentRooms do
  use Ecto.Migration

  def change do
    create table(:agent_rooms) do
      add :workspace_id, references(:workspaces, on_delete: :delete_all), null: false
      add :coordinator_agent_id, references(:agent_profiles, on_delete: :nilify_all)
      add :title, :string, null: false
      add :slug, :string, null: false
      add :status, :string, null: false, default: "active"
      add :routing_policy, :map, null: false, default: %{}
      add :metadata, :map, null: false, default: %{}
      add :last_message_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:agent_rooms, [:workspace_id, :slug])
    create index(:agent_rooms, [:workspace_id, :status])
    create index(:agent_rooms, [:coordinator_agent_id])

    create table(:agent_room_members) do
      add :workspace_id, references(:workspaces, on_delete: :delete_all), null: false
      add :room_id, references(:agent_rooms, on_delete: :delete_all), null: false
      add :agent_id, references(:agent_profiles, on_delete: :delete_all), null: false
      add :mention_handle, :string, null: false
      add :role, :string, null: false, default: "participant"
      add :response_mode, :string, null: false, default: "on_mention"
      add :priority, :integer, null: false, default: 0
      add :metadata, :map, null: false, default: %{}

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:agent_room_members, [:room_id, :agent_id])
    create unique_index(:agent_room_members, [:room_id, :mention_handle])
    create index(:agent_room_members, [:workspace_id, :room_id])

    create table(:agent_room_messages) do
      add :workspace_id, references(:workspaces, on_delete: :delete_all), null: false
      add :room_id, references(:agent_rooms, on_delete: :delete_all), null: false
      add :agent_id, references(:agent_profiles, on_delete: :nilify_all)
      add :conversation_id, references(:conversations, on_delete: :nilify_all)
      add :turn_id, references(:turns, on_delete: :nilify_all)
      add :author_type, :string, null: false
      add :source_channel, :string, null: false, default: "web"
      add :external_message_id, :string
      add :content, :text, null: false
      add :metadata, :map, null: false, default: %{}

      timestamps(type: :utc_datetime_usec)
    end

    create index(:agent_room_messages, [:workspace_id, :room_id, :inserted_at])

    create unique_index(:agent_room_messages, [:room_id, :source_channel, :external_message_id],
             where: "external_message_id IS NOT NULL"
           )

    create table(:room_channel_bindings) do
      add :workspace_id, references(:workspaces, on_delete: :delete_all), null: false
      add :room_id, references(:agent_rooms, on_delete: :delete_all), null: false
      add :provider, :string, null: false
      add :slug, :string, null: false
      add :status, :string, null: false, default: "active"
      add :external_chat_id, :string, null: false
      add :token_env, :string
      add :secret_env, :string
      add :config, :map, null: false, default: %{}
      add :last_received_at, :utc_datetime_usec
      add :last_sent_at, :utc_datetime_usec
      add :last_error, :map, null: false, default: %{}
      add :metadata, :map, null: false, default: %{}

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:room_channel_bindings, [:slug])
    create unique_index(:room_channel_bindings, [:provider, :external_chat_id])
    create index(:room_channel_bindings, [:workspace_id, :room_id])
    create index(:room_channel_bindings, [:provider, :status])
  end
end
