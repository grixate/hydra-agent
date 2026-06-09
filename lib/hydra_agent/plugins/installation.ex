defmodule HydraAgent.Plugins.Installation do
  use Ecto.Schema
  import Ecto.Changeset

  @statuses ~w(installed enabled disabled blocked uninstalled)
  @source_types ~w(local_path git)
  @trust_levels ~w(external trusted)

  schema "plugin_installations" do
    field :slug, :string
    field :name, :string
    field :version, :string
    field :description, :string
    field :status, :string, default: "installed"
    field :source_type, :string
    field :source_url, :string
    field :source_path, :string
    field :source_ref, :string
    field :trust_level, :string, default: "external"
    field :manifest, :map, default: %{}
    field :manifest_digest, :string
    field :permissions, :map, default: %{}
    field :env_refs, {:array, :string}, default: []
    field :last_error, :map, default: %{}
    field :approved_by, :string
    field :approved_at, :utc_datetime_usec
    field :metadata, :map, default: %{}

    belongs_to :workspace, HydraAgent.Runtime.Workspace
    has_many :capabilities, HydraAgent.Plugins.Capability, foreign_key: :plugin_installation_id
    has_many :events, HydraAgent.Plugins.Event, foreign_key: :plugin_installation_id
    has_one :configuration, HydraAgent.Plugins.Configuration, foreign_key: :plugin_installation_id

    timestamps(type: :utc_datetime_usec)
  end

  def statuses, do: @statuses
  def source_types, do: @source_types
  def trust_levels, do: @trust_levels

  def changeset(installation, attrs) do
    installation
    |> cast(attrs, [
      :workspace_id,
      :slug,
      :name,
      :version,
      :description,
      :status,
      :source_type,
      :source_url,
      :source_path,
      :source_ref,
      :trust_level,
      :manifest,
      :manifest_digest,
      :permissions,
      :env_refs,
      :last_error,
      :approved_by,
      :approved_at,
      :metadata
    ])
    |> validate_required([
      :workspace_id,
      :slug,
      :name,
      :version,
      :status,
      :source_type,
      :trust_level,
      :manifest,
      :manifest_digest,
      :permissions
    ])
    |> validate_format(:slug, ~r/^[a-z0-9][a-z0-9-]*$/)
    |> validate_inclusion(:status, @statuses)
    |> validate_inclusion(:source_type, @source_types)
    |> validate_inclusion(:trust_level, @trust_levels)
    |> validate_env_refs()
    |> validate_source()
    |> assoc_constraint(:workspace)
    |> unique_constraint([:workspace_id, :slug])
  end

  defp validate_env_refs(changeset) do
    validate_change(changeset, :env_refs, fn :env_refs, refs ->
      invalid =
        Enum.reject(refs || [], fn
          ref when is_binary(ref) -> Regex.match?(~r/^[A-Z][A-Z0-9_]*$/, ref)
          _ref -> false
        end)

      if invalid == [] do
        []
      else
        [env_refs: "must contain only environment variable names: #{Enum.join(invalid, ", ")}"]
      end
    end)
  end

  defp validate_source(changeset) do
    case get_field(changeset, :source_type) do
      "local_path" -> validate_required(changeset, [:source_path])
      "git" -> validate_required(changeset, [:source_url, :source_ref])
      _source_type -> changeset
    end
  end
end
