defmodule HydraAgent.Rooms.Message do
  use Ecto.Schema
  import Ecto.Changeset

  @author_types ~w(user agent system)
  @source_channels ~w(web telegram api system)

  schema "agent_room_messages" do
    field :author_type, :string
    field :source_channel, :string, default: "web"
    field :external_message_id, :string
    field :content, :string
    field :metadata, :map, default: %{}

    belongs_to :workspace, HydraAgent.Runtime.Workspace
    belongs_to :room, HydraAgent.Rooms.Room
    belongs_to :agent, HydraAgent.Runtime.AgentProfile
    belongs_to :conversation, HydraAgent.Runtime.Conversation
    belongs_to :turn, HydraAgent.Runtime.Turn
    has_many :deliveries, HydraAgent.Rooms.Delivery, foreign_key: :message_id

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(message, attrs) do
    message
    |> cast(attrs, [
      :workspace_id,
      :room_id,
      :agent_id,
      :conversation_id,
      :turn_id,
      :author_type,
      :source_channel,
      :external_message_id,
      :content,
      :metadata
    ])
    |> validate_required([:workspace_id, :room_id, :author_type, :source_channel, :content])
    |> validate_inclusion(:author_type, @author_types)
    |> validate_inclusion(:source_channel, @source_channels)
    |> assoc_constraint(:workspace)
    |> assoc_constraint(:room)
    |> assoc_constraint(:agent)
    |> assoc_constraint(:conversation)
    |> assoc_constraint(:turn)
    |> unique_constraint([:room_id, :source_channel, :external_message_id])
  end
end
