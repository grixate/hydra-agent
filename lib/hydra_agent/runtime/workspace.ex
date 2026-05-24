defmodule HydraAgent.Runtime.Workspace do
  use Ecto.Schema
  import Ecto.Changeset

  @statuses ~w(active paused archived)

  schema "workspaces" do
    field :name, :string
    field :slug, :string
    field :description, :string
    field :status, :string, default: "active"
    field :settings, :map, default: %{}

    has_many :agents, HydraAgent.Runtime.AgentProfile
    has_many :runs, HydraAgent.Runtime.Run
    has_many :conversations, HydraAgent.Runtime.Conversation
    has_many :knowledge_nodes, HydraAgent.Knowledge.Node

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(workspace, attrs) do
    workspace
    |> cast(attrs, [:name, :slug, :description, :status, :settings])
    |> validate_required([:name, :slug, :status])
    |> validate_format(:slug, ~r/^[a-z0-9][a-z0-9-]*$/)
    |> validate_inclusion(:status, @statuses)
    |> unique_constraint(:slug)
  end
end
