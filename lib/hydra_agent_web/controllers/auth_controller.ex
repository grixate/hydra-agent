defmodule HydraAgentWeb.AuthController do
  use HydraAgentWeb, :controller

  alias HydraAgent.Setup
  alias HydraAgentWeb.AdminAuth

  def new(conn, _params) do
    cond do
      not AdminAuth.enabled?() ->
        redirect(conn, to: default_signed_in_path())

      error = AdminAuth.setup_error() ->
        conn
        |> put_status(:service_unavailable)
        |> render(:setup_error, error: error)

      AdminAuth.authenticated?(get_session(conn)) ->
        redirect(conn, to: default_signed_in_path())

      true ->
        render(conn, :new, username: "", return_to: safe_return_to(conn.params["return_to"]))
    end
  end

  def create(conn, params) do
    username = params["username"] || ""
    password = params["password"] || ""
    return_to = safe_return_to(params["return_to"])
    rate_limit_key = rate_limit_key(conn, username)

    if AdminAuth.rate_limited?(rate_limit_key) do
      conn
      |> put_status(:too_many_requests)
      |> put_flash(:error, "Too many failed sign-in attempts. Try again later.")
      |> render(:new, username: username, return_to: return_to)
    else
      case AdminAuth.verify(username, password) do
        :ok ->
          AdminAuth.clear_failed_attempts(rate_limit_key)

          conn
          |> configure_session(renew: true)
          |> put_session(AdminAuth.session_key(), AdminAuth.session_payload(username))
          |> put_flash(:info, "Signed in.")
          |> redirect(to: return_to)

        {:error, error} ->
          AdminAuth.record_failed_attempt(rate_limit_key)

          conn
          |> put_status(status_for_error(error))
          |> put_flash(:error, "Invalid admin credentials.")
          |> render(:new, username: username, return_to: return_to)
      end
    end
  end

  def delete(conn, _params) do
    conn
    |> configure_session(drop: true)
    |> redirect(to: "/login")
  end

  defp status_for_error(%{"reason" => "missing_secret_env"}), do: :service_unavailable
  defp status_for_error(_error), do: :unauthorized

  defp safe_return_to(nil), do: default_signed_in_path()
  defp safe_return_to(""), do: default_signed_in_path()
  defp safe_return_to("/login"), do: default_signed_in_path()

  defp safe_return_to("/" <> _rest = path) do
    if String.starts_with?(path, "//"), do: "/control", else: path
  end

  defp safe_return_to(_return_to), do: "/control"

  defp default_signed_in_path do
    if Setup.first_run_required?(), do: "/setup", else: "/control"
  end

  defp rate_limit_key(conn, username) do
    ip =
      conn.remote_ip
      |> Tuple.to_list()
      |> Enum.join(".")

    "#{username}:#{ip}"
  end
end
