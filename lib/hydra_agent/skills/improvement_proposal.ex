defmodule HydraAgent.Skills.ImprovementProposal do
  use Ecto.Schema
  import Ecto.Changeset

  @kinds ~w(create refine prune)
  @statuses ~w(draft testing approved auto_activated rejected archived)

  schema "skill_improvement_proposals" do
    field :kind, :string
    field :status, :string, default: "draft"
    field :proposed_snapshot, :map, default: %{}
    field :evaluation_report, :map, default: %{}
    field :confidence, :float, default: 0.0
    field :metadata, :map, default: %{}

    belongs_to :workspace, HydraAgent.Runtime.Workspace
    belongs_to :target_skill, HydraAgent.Skills.Skill
    belongs_to :source_run, HydraAgent.Runtime.Run
    belongs_to :source_conversation, HydraAgent.Runtime.Conversation
    belongs_to :source_room, HydraAgent.Rooms.Room

    timestamps(type: :utc_datetime_usec)
  end

  def kinds, do: @kinds
  def statuses, do: @statuses

  def changeset(proposal, attrs) do
    proposal
    |> cast(attrs, [
      :workspace_id,
      :target_skill_id,
      :source_run_id,
      :source_conversation_id,
      :source_room_id,
      :kind,
      :status,
      :proposed_snapshot,
      :evaluation_report,
      :confidence,
      :metadata
    ])
    |> validate_required([:workspace_id, :kind, :status])
    |> validate_inclusion(:kind, @kinds)
    |> validate_inclusion(:status, @statuses)
    |> validate_number(:confidence, greater_than_or_equal_to: 0.0, less_than_or_equal_to: 1.0)
    |> assoc_constraint(:workspace)
    |> assoc_constraint(:target_skill)
    |> assoc_constraint(:source_run)
    |> assoc_constraint(:source_conversation)
    |> assoc_constraint(:source_room)
  end
end
