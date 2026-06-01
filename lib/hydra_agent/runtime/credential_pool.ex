defmodule HydraAgent.Runtime.CredentialPool do
  use Ecto.Schema
  import Ecto.Changeset

  @kinds ~w(provider tool gateway generic)
  @statuses ~w(active paused archived)

  schema "credential_pools" do
    field :name, :string
    field :slug, :string
    field :kind, :string, default: "provider"
    field :status, :string, default: "active"
    field :env_vars, {:array, :string}, default: []
    field :metadata, :map, default: %{}

    belongs_to :workspace, HydraAgent.Runtime.Workspace
    has_many :providers, HydraAgent.Runtime.ProviderConfig
    has_many :items, HydraAgent.Runtime.CredentialPoolItem

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(pool, attrs) do
    pool
    |> cast(attrs, [:workspace_id, :name, :slug, :kind, :status, :env_vars, :metadata])
    |> put_slug()
    |> validate_required([:name, :slug, :kind, :status])
    |> validate_format(:slug, ~r/^[a-z0-9]+(?:-[a-z0-9]+)*$/)
    |> validate_inclusion(:kind, @kinds)
    |> validate_inclusion(:status, @statuses)
    |> validate_env_vars()
    |> assoc_constraint(:workspace)
    |> unique_constraint(:slug, name: :credential_pools_workspace_id_slug_index)
  end

  defp validate_env_vars(changeset) do
    env_vars = get_field(changeset, :env_vars) || []

    invalid =
      env_vars
      |> Enum.reject(&(is_binary(&1) and Regex.match?(~r/^[A-Z][A-Z0-9_]*$/, &1)))

    if invalid == [] do
      changeset
    else
      add_error(changeset, :env_vars, "must contain environment variable names")
    end
  end

  defp put_slug(changeset) do
    case get_field(changeset, :slug) do
      value when is_binary(value) and value != "" ->
        update_change(changeset, :slug, &slugify/1)

      _value ->
        put_change(changeset, :slug, slugify(get_field(changeset, :name) || "credential-pool"))
    end
  end

  defp slugify(value) do
    value
    |> to_string()
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "-")
    |> String.trim("-")
    |> case do
      "" -> "credential-pool"
      slug -> slug
    end
  end
end
