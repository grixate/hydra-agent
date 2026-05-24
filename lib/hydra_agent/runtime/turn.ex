defmodule HydraAgent.Runtime.Turn do
  use Ecto.Schema
  import Ecto.Changeset

  @roles ~w(system user assistant tool)
  @kinds ~w(message tool_call tool_result summary steering)

  schema "turns" do
    field :role, :string
    field :kind, :string, default: "message"
    field :content, :string
    field :metadata, :map, default: %{}

    belongs_to :conversation, HydraAgent.Runtime.Conversation
    belongs_to :run, HydraAgent.Runtime.Run

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(turn, attrs) do
    turn
    |> cast(attrs, [:conversation_id, :run_id, :role, :kind, :content, :metadata])
    |> validate_required([:conversation_id, :role, :kind, :content])
    |> validate_inclusion(:role, @roles)
    |> validate_inclusion(:kind, @kinds)
    |> assoc_constraint(:conversation)
    |> assoc_constraint(:run)
  end
end
