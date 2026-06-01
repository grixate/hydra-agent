defmodule HydraAgent.Browser.Session do
  use Ecto.Schema
  import Ecto.Changeset

  @statuses ~w(active idle closed failed expired)

  schema "browser_sessions" do
    field :status, :string, default: "active"
    field :current_url, :string
    field :worker_session_id, :string
    field :expires_at, :utc_datetime_usec
    field :last_error, :map, default: %{}
    field :metadata, :map, default: %{}

    belongs_to :workspace, HydraAgent.Runtime.Workspace
    belongs_to :agent, HydraAgent.Runtime.AgentProfile
    belongs_to :run, HydraAgent.Runtime.Run
    has_many :artifacts, HydraAgent.Browser.Artifact, foreign_key: :browser_session_id

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(session, attrs) do
    session
    |> cast(attrs, [
      :workspace_id,
      :agent_id,
      :run_id,
      :status,
      :current_url,
      :worker_session_id,
      :expires_at,
      :last_error,
      :metadata
    ])
    |> validate_required([:workspace_id, :status])
    |> validate_inclusion(:status, @statuses)
    |> assoc_constraint(:workspace)
    |> assoc_constraint(:agent)
    |> assoc_constraint(:run)
  end
end
