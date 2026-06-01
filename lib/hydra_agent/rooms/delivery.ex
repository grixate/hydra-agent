defmodule HydraAgent.Rooms.Delivery do
  use Ecto.Schema
  import Ecto.Changeset

  @statuses ~w(pending sent delivered failed skipped)

  schema "room_message_deliveries" do
    field :provider, :string
    field :external_message_id, :string
    field :status, :string, default: "pending"
    field :attempts, :integer, default: 0
    field :last_error, :map, default: %{}
    field :metadata, :map, default: %{}
    field :sent_at, :utc_datetime_usec
    field :acknowledged_at, :utc_datetime_usec

    belongs_to :workspace, HydraAgent.Runtime.Workspace
    belongs_to :room, HydraAgent.Rooms.Room
    belongs_to :message, HydraAgent.Rooms.Message
    belongs_to :channel_binding, HydraAgent.Rooms.ChannelBinding

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(delivery, attrs) do
    delivery
    |> cast(attrs, [
      :workspace_id,
      :room_id,
      :message_id,
      :channel_binding_id,
      :provider,
      :external_message_id,
      :status,
      :attempts,
      :last_error,
      :metadata,
      :sent_at,
      :acknowledged_at
    ])
    |> validate_required([
      :workspace_id,
      :room_id,
      :message_id,
      :channel_binding_id,
      :provider,
      :status
    ])
    |> validate_inclusion(:status, @statuses)
    |> validate_number(:attempts, greater_than_or_equal_to: 0)
    |> assoc_constraint(:workspace)
    |> assoc_constraint(:room)
    |> assoc_constraint(:message)
    |> assoc_constraint(:channel_binding)
    |> unique_constraint([:message_id, :channel_binding_id])
  end
end
