defmodule HydraAgent.Runtime.Mission do
  use Ecto.Schema
  import Ecto.Changeset

  @statuses ~w(draft planned running paused blocked awaiting_approval completed failed canceled archived)
  @mission_types ~w(research coding analysis monitoring planning knowledge_ingestion custom)
  @start_modes ~w(draft plan_only start_worker)

  schema "missions" do
    field :title, :string
    field :slug, :string
    field :objective, :string
    field :mission_type, :string, default: "custom"
    field :status, :string, default: "draft"
    field :priority, :integer, default: 0
    field :deadline_at, :utc_datetime_usec
    field :success_criteria, :map, default: %{}
    field :context, :map, default: %{}
    field :team, :map, default: %{}
    field :permissions, :map, default: %{}
    field :budget, :map, default: %{}
    field :start_mode, :string, default: "draft"
    field :metadata, :map, default: %{}
    field :started_at, :utc_datetime_usec
    field :completed_at, :utc_datetime_usec

    belongs_to :workspace, HydraAgent.Runtime.Workspace
    belongs_to :supervisor_agent, HydraAgent.Runtime.AgentProfile
    has_many :runs, HydraAgent.Runtime.Run

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(mission, attrs) do
    mission
    |> cast(attrs, [
      :workspace_id,
      :supervisor_agent_id,
      :title,
      :slug,
      :objective,
      :mission_type,
      :status,
      :priority,
      :deadline_at,
      :success_criteria,
      :context,
      :team,
      :permissions,
      :budget,
      :start_mode,
      :metadata,
      :started_at,
      :completed_at
    ])
    |> put_slug()
    |> validate_required([:workspace_id, :title, :slug, :objective, :mission_type, :status])
    |> validate_format(:slug, ~r/^[a-z0-9]+(?:-[a-z0-9]+)*$/)
    |> validate_inclusion(:mission_type, @mission_types)
    |> validate_inclusion(:status, @statuses)
    |> validate_inclusion(:start_mode, @start_modes)
    |> validate_number(:priority, greater_than_or_equal_to: 0, less_than_or_equal_to: 100)
    |> assoc_constraint(:workspace)
    |> assoc_constraint(:supervisor_agent)
    |> unique_constraint(:slug, name: :missions_workspace_id_slug_index)
  end

  def statuses, do: @statuses
  def mission_types, do: @mission_types
  def start_modes, do: @start_modes

  defp put_slug(changeset) do
    case get_field(changeset, :slug) do
      value when is_binary(value) and value != "" ->
        update_change(changeset, :slug, &slugify/1)

      _value ->
        put_change(changeset, :slug, slugify(get_field(changeset, :title) || "mission"))
    end
  end

  defp slugify(value) do
    value
    |> to_string()
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "-")
    |> String.trim("-")
    |> case do
      "" -> "mission"
      slug -> slug
    end
  end
end
