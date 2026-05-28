defmodule HydraAgent.Skills.Experiment do
  use Ecto.Schema
  import Ecto.Changeset

  @statuses ~w(planned running completed failed)

  schema "skill_experiments" do
    field :status, :string, default: "planned"
    field :candidate_snapshots, :map, default: %{}
    field :evaluation_report, :map, default: %{}
    field :winner_snapshot, :map, default: %{}
    field :metadata, :map, default: %{}

    belongs_to :workspace, HydraAgent.Runtime.Workspace
    belongs_to :skill, HydraAgent.Skills.Skill
    belongs_to :source_conversation, HydraAgent.Runtime.Conversation
    belongs_to :source_room, HydraAgent.Rooms.Room
    belongs_to :selected_proposal, HydraAgent.Skills.ImprovementProposal

    timestamps(type: :utc_datetime_usec)
  end

  def statuses, do: @statuses

  def changeset(experiment, attrs) do
    experiment
    |> cast(attrs, [
      :workspace_id,
      :skill_id,
      :source_conversation_id,
      :source_room_id,
      :selected_proposal_id,
      :status,
      :candidate_snapshots,
      :evaluation_report,
      :winner_snapshot,
      :metadata
    ])
    |> validate_required([:workspace_id, :skill_id, :status])
    |> validate_inclusion(:status, @statuses)
    |> assoc_constraint(:workspace)
    |> assoc_constraint(:skill)
    |> assoc_constraint(:source_conversation)
    |> assoc_constraint(:source_room)
    |> assoc_constraint(:selected_proposal)
  end
end
