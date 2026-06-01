defmodule HydraAgent.Skills.UsageEvent do
  use Ecto.Schema
  import Ecto.Changeset

  @outcomes ~w(observed success failure corrected)

  schema "skill_usage_events" do
    field :trigger_text, :string
    field :match_score, :float, default: 0.0
    field :outcome_status, :string, default: "observed"
    field :tool_count, :integer, default: 0
    field :error_summary, :string
    field :metadata, :map, default: %{}

    belongs_to :workspace, HydraAgent.Runtime.Workspace
    belongs_to :skill, HydraAgent.Skills.Skill
    belongs_to :agent, HydraAgent.Runtime.AgentProfile
    belongs_to :run, HydraAgent.Runtime.Run
    belongs_to :conversation, HydraAgent.Runtime.Conversation
    belongs_to :room, HydraAgent.Rooms.Room

    timestamps(type: :utc_datetime_usec)
  end

  def outcomes, do: @outcomes

  def changeset(event, attrs) do
    event
    |> cast(attrs, [
      :workspace_id,
      :skill_id,
      :agent_id,
      :run_id,
      :conversation_id,
      :room_id,
      :trigger_text,
      :match_score,
      :outcome_status,
      :tool_count,
      :error_summary,
      :metadata
    ])
    |> validate_required([:workspace_id, :outcome_status])
    |> validate_inclusion(:outcome_status, @outcomes)
    |> validate_number(:match_score, greater_than_or_equal_to: 0.0, less_than_or_equal_to: 1.0)
    |> validate_number(:tool_count, greater_than_or_equal_to: 0)
    |> assoc_constraint(:workspace)
    |> assoc_constraint(:skill)
    |> assoc_constraint(:agent)
    |> assoc_constraint(:run)
    |> assoc_constraint(:conversation)
    |> assoc_constraint(:room)
  end
end
