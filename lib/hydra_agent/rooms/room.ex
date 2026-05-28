defmodule HydraAgent.Rooms.Room do
  use Ecto.Schema
  import Ecto.Changeset

  @statuses ~w(active paused archived)

  schema "agent_rooms" do
    field :title, :string
    field :slug, :string
    field :status, :string, default: "active"
    field :routing_policy, :map, default: %{}
    field :metadata, :map, default: %{}
    field :last_message_at, :utc_datetime_usec

    belongs_to :workspace, HydraAgent.Runtime.Workspace
    belongs_to :coordinator_agent, HydraAgent.Runtime.AgentProfile
    has_many :members, HydraAgent.Rooms.Member, foreign_key: :room_id
    has_many :messages, HydraAgent.Rooms.Message, foreign_key: :room_id
    has_many :channel_bindings, HydraAgent.Rooms.ChannelBinding, foreign_key: :room_id

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(room, attrs) do
    room
    |> cast(attrs, [
      :workspace_id,
      :coordinator_agent_id,
      :title,
      :slug,
      :status,
      :routing_policy,
      :metadata,
      :last_message_at
    ])
    |> validate_required([:workspace_id, :title, :slug, :status])
    |> validate_format(:slug, ~r/^[a-z0-9][a-z0-9-]*$/)
    |> validate_inclusion(:status, @statuses)
    |> assoc_constraint(:workspace)
    |> assoc_constraint(:coordinator_agent)
    |> unique_constraint([:workspace_id, :slug])
  end
end
