defmodule HydraAgent.Runtime.ProviderConfig do
  use Ecto.Schema
  import Ecto.Changeset

  @kinds ~w(openai_compatible anthropic ollama mock)

  schema "provider_configs" do
    field :name, :string
    field :kind, :string, default: "openai_compatible"
    field :base_url, :string
    field :model, :string
    field :api_key_env, :string
    field :enabled, :boolean, default: true
    field :metadata, :map, default: %{}

    belongs_to :workspace, HydraAgent.Runtime.Workspace

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(provider, attrs) do
    provider
    |> cast(attrs, [
      :workspace_id,
      :name,
      :kind,
      :base_url,
      :model,
      :api_key_env,
      :enabled,
      :metadata
    ])
    |> validate_required([:name, :kind, :model])
    |> validate_inclusion(:kind, @kinds)
    |> validate_format(:api_key_env, ~r/^[A-Z][A-Z0-9_]*$/,
      message: "must name an environment variable"
    )
    |> assoc_constraint(:workspace)
  end
end
