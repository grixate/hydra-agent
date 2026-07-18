defmodule HydraAgentWeb.Plugs.RateLimit do
  @moduledoc "Fail-closed request limiting backed by PostgreSQL."

  import Plug.Conn

  alias HydraAgent.Security.RateLimiter
  alias HydraAgentWeb.ClientIp

  def init(opts), do: opts

  def call(conn, opts) do
    {limit, window_seconds} = configured_limit(conn, opts)
    scope = Keyword.fetch!(opts, :scope) <> ":" <> category(conn)
    identity = identity(conn, Keyword.get(opts, :identity, :remote))

    case RateLimiter.consume(scope, identity, limit, window_seconds) do
      {:ok, remaining, retry_after} ->
        conn
        |> put_resp_header("x-ratelimit-limit", Integer.to_string(limit))
        |> put_resp_header("x-ratelimit-remaining", Integer.to_string(remaining))
        |> put_resp_header("x-ratelimit-reset", Integer.to_string(retry_after))

      {:error, :rate_limited, retry_after} ->
        reject(conn, 429, retry_after, "request_rate_limited")

      {:error, _reason} ->
        reject(conn, 503, 5, "rate_limit_unavailable")
    end
  end

  defp configured_limit(conn, opts) do
    case Keyword.get(opts, :config) do
      nil ->
        {Keyword.fetch!(opts, :limit), Keyword.fetch!(opts, :window_seconds)}

      config_key ->
        config = Application.fetch_env!(:hydra_agent, :rate_limits)
        key = if config_key == :api, do: api_key(conn), else: config_key
        Keyword.fetch!(config, key)
    end
  end

  defp api_key(%{method: method}) when method in ~w(GET HEAD OPTIONS), do: :api_read
  defp api_key(_conn), do: :api_write

  defp category(%{method: method}) when method in ~w(GET HEAD OPTIONS), do: "read"
  defp category(_conn), do: "write"

  defp identity(conn, :api_credential) do
    authorization = conn |> get_req_header("authorization") |> List.first() || "missing"
    remote_identity(conn) <> ":" <> authorization
  end

  defp identity(conn, :user_workspace) do
    user_id = conn.assigns[:current_user] && conn.assigns.current_user.id
    workspace_id = conn.path_params["workspace_id"] || "none"
    "user:#{user_id || "anonymous"}:workspace:#{workspace_id}:#{remote_identity(conn)}"
  end

  defp identity(conn, :webhook) do
    slug = conn.path_params["slug"] || conn.path_params["binding_slug"] || "unknown"
    "webhook:#{slug}:#{remote_identity(conn)}"
  end

  defp identity(conn, :remote), do: remote_identity(conn)

  defp remote_identity(conn) do
    ClientIp.address(conn)
  end

  defp reject(conn, status, retry_after, reason) do
    body = Jason.encode!(%{errors: %{reason: reason, retry_after_seconds: retry_after}})

    conn
    |> put_resp_header("retry-after", Integer.to_string(retry_after))
    |> put_resp_content_type("application/json")
    |> send_resp(status, body)
    |> halt()
  end
end
