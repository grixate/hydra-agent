defmodule HydraAgent.Rooms.Member do
  use Ecto.Schema
  import Ecto.Changeset

  @roles ~w(coordinator participant observer)
  @response_modes ~w(on_mention coordinator silent)

  schema "agent_room_members" do
    field :mention_handle, :string
    field :role, :string, default: "participant"
    field :response_mode, :string, default: "on_mention"
    field :priority, :integer, default: 0
    field :metadata, :map, default: %{}

    belongs_to :workspace, HydraAgent.Runtime.Workspace
    belongs_to :room, HydraAgent.Rooms.Room
    belongs_to :agent, HydraAgent.Runtime.AgentProfile

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(member, attrs) do
    member
    |> cast(attrs, [
      :workspace_id,
      :room_id,
      :agent_id,
      :mention_handle,
      :role,
      :response_mode,
      :priority,
      :metadata
    ])
    |> normalize_handle()
    |> validate_required([:workspace_id, :room_id, :agent_id, :mention_handle, :role])
    |> validate_format(:mention_handle, ~r/^[a-z0-9][a-z0-9-]*$/)
    |> validate_inclusion(:role, @roles)
    |> validate_inclusion(:response_mode, @response_modes)
    |> assoc_constraint(:workspace)
    |> assoc_constraint(:room)
    |> assoc_constraint(:agent)
    |> unique_constraint([:room_id, :agent_id])
    |> unique_constraint([:room_id, :mention_handle])
  end

  defp normalize_handle(changeset) do
    update_change(changeset, :mention_handle, fn handle ->
      handle
      |> to_string()
      |> String.trim()
      |> String.trim_leading("@")
      |> String.downcase()
    end)
  end
end
