defmodule HydraAgent.Rooms.ChannelBinding do
  use Ecto.Schema
  import Ecto.Changeset

  @providers ~w(telegram)
  @statuses ~w(active paused archived)

  schema "room_channel_bindings" do
    field :provider, :string
    field :slug, :string
    field :status, :string, default: "active"
    field :external_chat_id, :string
    field :token_env, :string
    field :secret_env, :string
    field :config, :map, default: %{}
    field :last_received_at, :utc_datetime_usec
    field :last_sent_at, :utc_datetime_usec
    field :last_error, :map, default: %{}
    field :metadata, :map, default: %{}

    belongs_to :workspace, HydraAgent.Runtime.Workspace
    belongs_to :room, HydraAgent.Rooms.Room
    has_many :deliveries, HydraAgent.Rooms.Delivery, foreign_key: :channel_binding_id

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(binding, attrs) do
    binding
    |> cast(attrs, [
      :workspace_id,
      :room_id,
      :provider,
      :slug,
      :status,
      :external_chat_id,
      :token_env,
      :secret_env,
      :config,
      :last_received_at,
      :last_sent_at,
      :last_error,
      :metadata
    ])
    |> validate_required([:workspace_id, :room_id, :provider, :slug, :status, :external_chat_id])
    |> validate_format(:slug, ~r/^[a-z0-9][a-z0-9-]*$/)
    |> validate_inclusion(:provider, @providers)
    |> validate_inclusion(:status, @statuses)
    |> validate_env_ref(:token_env)
    |> validate_env_ref(:secret_env)
    |> assoc_constraint(:workspace)
    |> assoc_constraint(:room)
    |> unique_constraint(:slug)
    |> unique_constraint([:provider, :external_chat_id])
  end

  defp validate_env_ref(changeset, field) do
    validate_change(changeset, field, fn ^field, value ->
      cond do
        is_nil(value) or value == "" -> []
        Regex.match?(~r/^[A-Z][A-Z0-9_]*$/, value) -> []
        true -> [{field, "must be an environment variable name"}]
      end
    end)
  end
end
