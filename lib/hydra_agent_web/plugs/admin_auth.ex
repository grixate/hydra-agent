defmodule HydraAgentWeb.Plugs.AdminAuth do
  @moduledoc """
  Protects browser management routes with env-backed admin authentication.
  """

  import Plug.Conn
  import Phoenix.Controller

  alias HydraAgentWeb.AdminAuth

  def init(opts), do: opts

  def call(conn, _opts) do
    if AdminAuth.enabled?() do
      authenticate(conn)
    else
      conn
    end
  end

  defp authenticate(conn) do
    cond do
      not AdminAuth.configured?() ->
        conn
        |> put_status(:service_unavailable)
        |> put_resp_content_type("text/html")
        |> html(setup_error_html(AdminAuth.setup_error()))
        |> halt()

      AdminAuth.authenticated?(get_session(conn)) ->
        conn

      true ->
        conn
        |> put_flash(:error, "Sign in to continue.")
        |> redirect(to: "/login?return_to=#{URI.encode(conn.request_path)}")
        |> halt()
    end
  end

  defp setup_error_html(error) do
    reason = Map.get(error || %{}, "reason", "admin_auth_not_configured")
    env = Map.get(error || %{}, "env", "HYDRA_ADMIN_USERNAME / HYDRA_ADMIN_PASSWORD")

    """
    <main style="font-family: system-ui, sans-serif; max-width: 720px; margin: 80px auto;">
      <h1>Hydra admin auth is not configured</h1>
      <p>Protected browser routes are unavailable until the required admin environment variables are set.</p>
      <p><strong>Reason:</strong> #{escape(reason)}</p>
      <p><strong>Missing env:</strong> #{escape(env)}</p>
    </main>
    """
  end

  defp escape(value) do
    value
    |> to_string()
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
    |> String.replace("\"", "&quot;")
  end
end
