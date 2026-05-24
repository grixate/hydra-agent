defmodule HydraAgent.Runtime.AgentProfile do
  use Ecto.Schema
  import Ecto.Changeset

  alias HydraAgent.Runtime.Autonomy

  @statuses ~w(active paused archived)

  schema "agent_profiles" do
    field :name, :string
    field :slug, :string
    field :role, :string, default: "operator"
    field :status, :string, default: "active"
    field :description, :string
    field :system_prompt, :string
    field :model_route, :map, default: %{}
    field :capability_profile, :map, default: %{}
    field :memory_scopes, {:array, :string}, default: []
    field :knowledge_scopes, {:array, :string}, default: []
    field :runtime_state, :map, default: %{}

    belongs_to :workspace, HydraAgent.Runtime.Workspace
    has_many :conversations, HydraAgent.Runtime.Conversation, foreign_key: :agent_id
    has_many :runs, HydraAgent.Runtime.Run, foreign_key: :supervisor_agent_id
    has_many :assigned_steps, HydraAgent.Runtime.RunStep, foreign_key: :assigned_agent_id
    has_many :run_events, HydraAgent.Runtime.RunEvent, foreign_key: :agent_id

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(agent, attrs) do
    agent
    |> cast(attrs, [
      :workspace_id,
      :name,
      :slug,
      :role,
      :status,
      :description,
      :system_prompt,
      :model_route,
      :capability_profile,
      :memory_scopes,
      :knowledge_scopes,
      :runtime_state
    ])
    |> validate_required([:workspace_id, :name, :slug, :role, :status])
    |> validate_format(:slug, ~r/^[a-z0-9][a-z0-9-]*$/)
    |> validate_inclusion(:role, Autonomy.roles())
    |> validate_inclusion(:status, @statuses)
    |> assoc_constraint(:workspace)
    |> unique_constraint([:workspace_id, :slug])
  end
end
