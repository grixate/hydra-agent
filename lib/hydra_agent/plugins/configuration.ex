defmodule HydraAgent.Plugins.Configuration do
  use Ecto.Schema
  import Ecto.Changeset

  schema "plugin_configurations" do
    field :config, :map, default: %{}
    field :configured_by, :string
    field :configured_at, :utc_datetime_usec
    field :metadata, :map, default: %{}

    belongs_to :workspace, HydraAgent.Runtime.Workspace
    belongs_to :plugin_installation, HydraAgent.Plugins.Installation

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(configuration, attrs) do
    configuration
    |> cast(attrs, [
      :workspace_id,
      :plugin_installation_id,
      :config,
      :configured_by,
      :configured_at,
      :metadata
    ])
    |> validate_required([:workspace_id, :plugin_installation_id, :config])
    |> assoc_constraint(:workspace)
    |> assoc_constraint(:plugin_installation)
    |> unique_constraint(:plugin_installation_id)
  end
end
