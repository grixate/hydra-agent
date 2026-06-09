defmodule HydraAgent.Plugins.Event do
  use Ecto.Schema
  import Ecto.Changeset

  schema "plugin_events" do
    field :event_type, :string
    field :actor, :string, default: "operator"
    field :summary, :string
    field :payload, :map, default: %{}

    belongs_to :workspace, HydraAgent.Runtime.Workspace
    belongs_to :plugin_installation, HydraAgent.Plugins.Installation

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  def changeset(event, attrs) do
    event
    |> cast(attrs, [
      :workspace_id,
      :plugin_installation_id,
      :event_type,
      :actor,
      :summary,
      :payload
    ])
    |> validate_required([:workspace_id, :event_type, :actor, :summary, :payload])
    |> validate_format(:event_type, ~r/^[a-z0-9][a-z0-9_.:-]*$/)
    |> assoc_constraint(:workspace)
    |> assoc_constraint(:plugin_installation)
  end
end
