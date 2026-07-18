defmodule HydraAgent.Security.RateLimiter do
  @moduledoc "Database-backed fixed-window limits shared by every application node."

  alias HydraAgent.Repo

  @spec consume(String.t(), String.t(), pos_integer(), pos_integer()) ::
          {:ok, non_neg_integer(), pos_integer()}
          | {:error, :rate_limited, pos_integer()}
          | {:error, term()}
  def consume(scope, identity, limit, window_seconds)
      when is_binary(scope) and is_binary(identity) and is_integer(limit) and limit > 0 and
             is_integer(window_seconds) and window_seconds > 0 do
    now_seconds = System.system_time(:second)
    bucket_seconds = div(now_seconds, window_seconds) * window_seconds
    bucket_start = DateTime.from_unix!(bucket_seconds)
    expires_at = DateTime.from_unix!(bucket_seconds + window_seconds * 2)
    retry_after = max(bucket_seconds + window_seconds - now_seconds, 1)
    key_hash = :crypto.hash(:sha256, identity)

    sql = """
    INSERT INTO request_rate_limit_buckets
      (scope, key_hash, bucket_start, request_count, expires_at, inserted_at, updated_at)
    VALUES ($1, $2, $3, 1, $4, NOW(), NOW())
    ON CONFLICT (scope, key_hash, bucket_start)
    DO UPDATE SET
      request_count = request_rate_limit_buckets.request_count + 1,
      updated_at = NOW()
    RETURNING request_count
    """

    case Repo.query(sql, [scope, key_hash, bucket_start, expires_at]) do
      {:ok, %{rows: [[count]]}} when count <= limit -> {:ok, limit - count, retry_after}
      {:ok, %{rows: [[_count]]}} -> {:error, :rate_limited, retry_after}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec status(String.t(), String.t(), pos_integer(), pos_integer()) ::
          {:ok, non_neg_integer(), pos_integer()}
          | {:error, :rate_limited, pos_integer()}
          | {:error, term()}
  def status(scope, identity, limit, window_seconds)
      when is_binary(scope) and is_binary(identity) and is_integer(limit) and limit > 0 and
             is_integer(window_seconds) and window_seconds > 0 do
    {bucket_start, retry_after} = window(window_seconds)
    key_hash = :crypto.hash(:sha256, identity)

    sql = """
    SELECT request_count
    FROM request_rate_limit_buckets
    WHERE scope = $1 AND key_hash = $2 AND bucket_start = $3
    """

    case Repo.query(sql, [scope, key_hash, bucket_start]) do
      {:ok, %{rows: []}} -> {:ok, limit, retry_after}
      {:ok, %{rows: [[count]]}} when count < limit -> {:ok, limit - count, retry_after}
      {:ok, %{rows: [[_count]]}} -> {:error, :rate_limited, retry_after}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec clear(String.t(), String.t()) :: :ok | {:error, term()}
  def clear(scope, identity) when is_binary(scope) and is_binary(identity) do
    key_hash = :crypto.hash(:sha256, identity)

    case Repo.query(
           "DELETE FROM request_rate_limit_buckets WHERE scope = $1 AND key_hash = $2",
           [scope, key_hash]
         ) do
      {:ok, _result} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  def prune_expired do
    Repo.query("DELETE FROM request_rate_limit_buckets WHERE expires_at < NOW()")
  end

  defp window(window_seconds) do
    now_seconds = System.system_time(:second)
    bucket_seconds = div(now_seconds, window_seconds) * window_seconds
    {DateTime.from_unix!(bucket_seconds), max(bucket_seconds + window_seconds - now_seconds, 1)}
  end
end
