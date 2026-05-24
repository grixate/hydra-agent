defmodule HydraAgent.Runtime.Conversation do
  use Ecto.Schema
  import Ecto.Changeset

  @statuses ~w(active paused archived)

  schema "conversations" do
    field :title, :string
    field :channel, :string, default: "control_plane"
    field :status, :string, default: "active"
    field :metadata, :map, default: %{}
    field :last_message_at, :utc_datetime_usec

    belongs_to :workspace, HydraAgent.Runtime.Workspace
    belongs_to :agent, HydraAgent.Runtime.AgentProfile
    has_many :turns, HydraAgent.Runtime.Turn

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(conversation, attrs) do
    conversation
    |> cast(attrs, [
      :workspace_id,
      :agent_id,
      :title,
      :channel,
      :status,
      :metadata,
      :last_message_at
    ])
    |> validate_required([:workspace_id, :agent_id, :channel, :status])
    |> validate_inclusion(:status, @statuses)
    |> assoc_constraint(:workspace)
    |> assoc_constraint(:agent)
  end
end
