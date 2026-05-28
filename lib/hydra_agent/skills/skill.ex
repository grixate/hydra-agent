defmodule HydraAgent.Skills.Skill do
  use Ecto.Schema
  import Ecto.Changeset

  alias HydraAgent.Tools.Registry

  @statuses ~w(proposed testing active deprecated archived)

  schema "skills" do
    field :name, :string
    field :slug, :string
    field :description, :string
    field :status, :string, default: "proposed"
    field :instructions, :string
    field :trigger_conditions, :map, default: %{}
    field :required_tools, {:array, :string}, default: []
    field :memory_scopes, {:array, :string}, default: []
    field :knowledge_scopes, {:array, :string}, default: []
    field :evals, :map, default: %{}
    field :provenance, :map, default: %{}
    field :activated_at, :utc_datetime_usec
    field :deprecated_at, :utc_datetime_usec

    belongs_to :workspace, HydraAgent.Runtime.Workspace
    belongs_to :owner_agent, HydraAgent.Runtime.AgentProfile
    belongs_to :source_run, HydraAgent.Runtime.Run
    has_many :versions, HydraAgent.Skills.SkillVersion

    timestamps(type: :utc_datetime_usec)
  end

  def statuses, do: @statuses

  def changeset(skill, attrs) do
    skill
    |> cast(attrs, [
      :workspace_id,
      :owner_agent_id,
      :source_run_id,
      :name,
      :slug,
      :description,
      :status,
      :instructions,
      :trigger_conditions,
      :required_tools,
      :memory_scopes,
      :knowledge_scopes,
      :evals,
      :provenance,
      :activated_at,
      :deprecated_at
    ])
    |> validate_required([:workspace_id, :name, :slug, :description, :status, :instructions])
    |> validate_format(:slug, ~r/^[a-z0-9][a-z0-9-]*$/)
    |> validate_inclusion(:status, @statuses)
    |> validate_known_tools()
    |> assoc_constraint(:workspace)
    |> assoc_constraint(:owner_agent)
    |> assoc_constraint(:source_run)
    |> unique_constraint([:workspace_id, :slug])
  end

  defp validate_known_tools(changeset) do
    validate_change(changeset, :required_tools, fn :required_tools, tools ->
      unknown = tools -- Registry.names()

      if unknown == [],
        do: [],
        else: [required_tools: "contains unknown registered tools: #{Enum.join(unknown, ", ")}"]
    end)
  end
end
