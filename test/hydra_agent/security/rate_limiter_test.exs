defmodule HydraAgent.Security.RateLimiterTest do
  use HydraAgent.DataCase, async: false

  alias HydraAgent.Security.RateLimiter

  test "shares a durable fixed-window request budget" do
    identity = "test-#{System.unique_integer([:positive])}"

    assert {:ok, 1, _retry_after} = RateLimiter.consume("test", identity, 2, 60)
    assert {:ok, 0, _retry_after} = RateLimiter.consume("test", identity, 2, 60)
    assert {:error, :rate_limited, retry_after} = RateLimiter.consume("test", identity, 2, 60)
    assert retry_after in 1..60
  end

  test "reads and clears a shared limit without consuming another request" do
    identity = "status-#{System.unique_integer([:positive])}"

    assert {:ok, 2, _retry_after} = RateLimiter.status("status-test", identity, 2, 60)
    assert {:ok, 1, _retry_after} = RateLimiter.consume("status-test", identity, 2, 60)
    assert {:ok, 1, _retry_after} = RateLimiter.status("status-test", identity, 2, 60)
    assert :ok = RateLimiter.clear("status-test", identity)
    assert {:ok, 2, _retry_after} = RateLimiter.status("status-test", identity, 2, 60)
  end

  test "prunes expired buckets" do
    Repo.query!(
      """
      INSERT INTO request_rate_limit_buckets
        (scope, key_hash, bucket_start, request_count, expires_at, inserted_at, updated_at)
      VALUES ('expired-test', $1, NOW(), 1, NOW() - INTERVAL '1 second', NOW(), NOW())
      """,
      [:crypto.strong_rand_bytes(32)]
    )

    assert {:ok, %{num_rows: count}} = RateLimiter.prune_expired()
    assert count >= 1
  end
end
