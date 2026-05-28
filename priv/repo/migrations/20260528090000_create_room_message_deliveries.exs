defmodule HydraAgent.Repo.Migrations.CreateRoomMessageDeliveries do
  use Ecto.Migration

  def change do
    create table(:room_message_deliveries) do
      add :workspace_id, references(:workspaces, on_delete: :delete_all), null: false
      add :room_id, references(:agent_rooms, on_delete: :delete_all), null: false
      add :message_id, references(:agent_room_messages, on_delete: :delete_all), null: false

      add :channel_binding_id, references(:room_channel_bindings, on_delete: :delete_all),
        null: false

      add :provider, :string, null: false
      add :external_message_id, :string
      add :status, :string, null: false, default: "pending"
      add :attempts, :integer, null: false, default: 0
      add :last_error, :map, null: false, default: %{}
      add :metadata, :map, null: false, default: %{}
      add :sent_at, :utc_datetime_usec
      add :acknowledged_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:room_message_deliveries, [:message_id, :channel_binding_id])
    create index(:room_message_deliveries, [:workspace_id, :room_id, :status])
    create index(:room_message_deliveries, [:channel_binding_id, :status])
    create index(:room_message_deliveries, [:provider, :status])
  end
end
