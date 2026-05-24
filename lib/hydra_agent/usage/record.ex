defmodule HydraAgent.Usage.Record do
  use Ecto.Schema
  import Ecto.Changeset

  @categories ~w(chat planning eval embedding tool)
  @statuses ~w(ok error)

  schema "usage_records" do
    field :provider, :string
    field :model, :string
    field :category, :string
    field :status, :string, default: "ok"
    field :input_tokens, :integer, default: 0
    field :output_tokens, :integer, default: 0
    field :total_tokens, :integer, default: 0
    field :estimated_cost, :decimal
    field :latency_ms, :integer
    field :metadata, :map, default: %{}

    belongs_to :workspace, HydraAgent.Runtime.Workspace
    belongs_to :agent, HydraAgent.Runtime.AgentProfile
    belongs_to :run, HydraAgent.Runtime.Run
    belongs_to :run_step, HydraAgent.Runtime.RunStep
    belongs_to :conversation, HydraAgent.Runtime.Conversation
    belongs_to :turn, HydraAgent.Runtime.Turn

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  def changeset(record, attrs) do
    record
    |> cast(attrs, [
      :workspace_id,
      :agent_id,
      :run_id,
      :run_step_id,
      :conversation_id,
      :turn_id,
      :provider,
      :model,
      :category,
      :status,
      :input_tokens,
      :output_tokens,
      :total_tokens,
      :estimated_cost,
      :latency_ms,
      :metadata
    ])
    |> validate_required([:workspace_id, :category, :status])
    |> validate_inclusion(:category, @categories)
    |> validate_inclusion(:status, @statuses)
    |> validate_number(:input_tokens, greater_than_or_equal_to: 0)
    |> validate_number(:output_tokens, greater_than_or_equal_to: 0)
    |> validate_number(:total_tokens, greater_than_or_equal_to: 0)
    |> assoc_constraint(:workspace)
    |> assoc_constraint(:agent)
    |> assoc_constraint(:run)
    |> assoc_constraint(:run_step)
    |> assoc_constraint(:conversation)
    |> assoc_constraint(:turn)
  end
end
