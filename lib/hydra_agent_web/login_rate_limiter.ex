defmodule HydraAgentWeb.LoginRateLimiter do
  @moduledoc false
  alias HydraAgent.Security.RateLimiter
  alias HydraAgentWeb.ClientIp

  @scope "browser_login_failures"
  @ip_scope "browser_login_failures_by_ip"
  @window_seconds 15 * 60
  @max_failures 10
  @max_ip_failures 60

  def key(conn, email) do
    normalized = String.downcase(String.trim(to_string(email)))
    address = ClientIp.address(conn)

    %{
      credential: :crypto.hash(:sha256, address <> ":" <> normalized),
      ip: :crypto.hash(:sha256, address)
    }
  end

  def allowed?(%{credential: credential, ip: ip}) do
    allowed?(@scope, credential, @max_failures) and allowed?(@ip_scope, ip, @max_ip_failures)
  end

  def record_failure(%{credential: credential, ip: ip}) do
    with :ok <- consume(@scope, credential, @max_failures),
         :ok <- consume(@ip_scope, ip, @max_ip_failures) do
      :ok
    end
  end

  # A successful login clears only that identity's failures. It must not let
  # one valid credential reset the shared protection for the source address.
  def clear(%{credential: credential}), do: RateLimiter.clear(@scope, credential)

  defp allowed?(scope, key, limit) do
    case RateLimiter.status(scope, key, limit, @window_seconds) do
      {:ok, _remaining, _retry_after} -> true
      {:error, _reason, _retry_after} -> false
      {:error, _reason} -> false
    end
  end

  defp consume(scope, key, limit) do
    case RateLimiter.consume(scope, key, limit, @window_seconds) do
      {:ok, _remaining, _retry_after} -> :ok
      {:error, :rate_limited, _retry_after} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end
end
