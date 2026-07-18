defmodule HydraAgent.ApiCredentials do
  @moduledoc "Hashed, scoped, expiring and revocable API credentials."

  import Ecto.Query

  alias HydraAgent.Accounts.ApiAccessToken
  alias HydraAgent.Repo

  @permissions ~w(read write)

  def issue_token(attrs) do
    raw_token = "hydra_" <> Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
    prefix = String.slice(raw_token, 0, 14)

    attrs =
      attrs
      |> Map.new()
      |> Map.put(:token_prefix, prefix)
      |> Map.put(:token_hash, digest(raw_token))

    case %ApiAccessToken{} |> ApiAccessToken.changeset(attrs) |> Repo.insert() do
      {:ok, record} -> {:ok, %{token: raw_token, record: record}}
      {:error, changeset} -> {:error, changeset}
    end
  end

  def authenticate(raw_token, method, workspace_id) when is_binary(raw_token) do
    required_permission = if method in ~w(GET HEAD OPTIONS), do: "read", else: "write"
    now = DateTime.utc_now()

    token = Repo.get_by(ApiAccessToken, token_hash: digest(raw_token))

    with %ApiAccessToken{} = token <- token,
         :ok <- verify_active(token, now),
         :ok <- verify_permission(token, required_permission),
         :ok <- verify_workspace_scope(token, workspace_id) do
      touch_last_used(token.id, now)

      {:ok,
       %{
         type: :database_token,
         token_id: token.id,
         token_prefix: token.token_prefix,
         workspace_id: token.workspace_id,
         permissions: token.permissions
       }}
    else
      nil -> {:error, :invalid_token}
      {:error, reason} -> {:error, reason}
    end
  end

  def revoke_by_prefix(prefix) when is_binary(prefix) do
    now = DateTime.utc_now()

    ApiAccessToken
    |> where([token], token.token_prefix == ^prefix and is_nil(token.revoked_at))
    |> Repo.update_all(set: [revoked_at: now, updated_at: now])
    |> case do
      {1, _} -> :ok
      {0, _} -> {:error, :not_found}
    end
  end

  def list_tokens(workspace_id) do
    ApiAccessToken
    |> where([token], token.workspace_id == ^workspace_id)
    |> order_by([token], desc: token.inserted_at)
    |> Repo.all()
  end

  def valid_permissions?(permissions),
    do:
      is_list(permissions) and permissions != [] and Enum.all?(permissions, &(&1 in @permissions))

  defp verify_active(%ApiAccessToken{revoked_at: revoked_at}, _now)
       when not is_nil(revoked_at),
       do: {:error, :invalid_token}

  defp verify_active(%ApiAccessToken{expires_at: nil}, _now), do: :ok

  defp verify_active(%ApiAccessToken{expires_at: expires_at}, now) do
    if DateTime.compare(expires_at, now) == :gt,
      do: :ok,
      else: {:error, :invalid_token}
  end

  defp verify_permission(%ApiAccessToken{permissions: permissions}, required_permission) do
    if required_permission in permissions,
      do: :ok,
      else: {:error, :insufficient_permission}
  end

  defp verify_workspace_scope(%{workspace_id: nil}, _workspace_id), do: :ok

  defp verify_workspace_scope(%{workspace_id: workspace_id}, request_workspace_id)
       when is_integer(workspace_id) do
    case parse_id(request_workspace_id) do
      ^workspace_id -> :ok
      nil -> {:error, :workspace_scope_required}
      _other -> {:error, :workspace_scope_mismatch}
    end
  end

  defp parse_id(value) when is_integer(value), do: value

  defp parse_id(value) when is_binary(value) do
    case Integer.parse(value) do
      {id, ""} -> id
      _ -> nil
    end
  end

  defp parse_id(_value), do: nil

  defp touch_last_used(id, now) do
    ApiAccessToken
    |> where([token], token.id == ^id)
    |> Repo.update_all(set: [last_used_at: now, updated_at: now])
  end

  defp digest(token), do: :crypto.hash(:sha256, token)
end
