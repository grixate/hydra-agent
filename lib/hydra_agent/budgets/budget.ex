defmodule HydraAgent.Budgets.Budget do
  use Ecto.Schema
  import Ecto.Changeset

  @statuses ~w(active paused archived)
  @periods ~w(daily weekly monthly total)
  @categories ~w(chat planning eval embedding tool)

  schema "budgets" do
    field :name, :string
    field :status, :string, default: "active"
    field :category, :string
    field :period, :string, default: "monthly"
    field :token_limit, :integer
    field :cost_limit, :decimal
    field :metadata, :map, default: %{}

    belongs_to :workspace, HydraAgent.Runtime.Workspace
    belongs_to :agent, HydraAgent.Runtime.AgentProfile

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(budget, attrs) do
    budget
    |> cast(attrs, [
      :workspace_id,
      :agent_id,
      :name,
      :status,
      :category,
      :period,
      :token_limit,
      :cost_limit,
      :metadata
    ])
    |> validate_required([:workspace_id, :name, :status, :period])
    |> validate_inclusion(:status, @statuses)
    |> validate_inclusion(:period, @periods)
    |> validate_inclusion(:category, @categories)
    |> validate_number(:token_limit, greater_than: 0)
    |> assoc_constraint(:workspace)
    |> assoc_constraint(:agent)
  end
end
