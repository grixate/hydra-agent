defmodule HydraAgent.Browser.Artifact do
  use Ecto.Schema
  import Ecto.Changeset

  @kinds ~w(screenshot extract console network step)

  schema "browser_artifacts" do
    field :kind, :string
    field :content_type, :string
    field :content, :string
    field :uri, :string
    field :metadata, :map, default: %{}

    belongs_to :workspace, HydraAgent.Runtime.Workspace
    belongs_to :browser_session, HydraAgent.Browser.Session

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(artifact, attrs) do
    artifact
    |> cast(attrs, [
      :workspace_id,
      :browser_session_id,
      :kind,
      :content_type,
      :content,
      :uri,
      :metadata
    ])
    |> validate_required([:workspace_id, :browser_session_id, :kind])
    |> validate_inclusion(:kind, @kinds)
    |> assoc_constraint(:workspace)
    |> assoc_constraint(:browser_session)
  end
end
