defmodule HydraAgentWeb.UserAuth do
  @moduledoc "Browser session authentication and LiveView identity loading."

  use HydraAgentWeb, :verified_routes

  import Phoenix.Controller
  import Plug.Conn

  alias HydraAgent.Accounts
  alias HydraAgentWeb.Endpoint

  def init(action), do: action
  def call(conn, action), do: apply(__MODULE__, action, [conn, []])

  def fetch_current_user(conn, _opts) do
    user =
      Accounts.get_session_user(get_session(conn, :user_id), get_session(conn, :session_version))

    assign(conn, :current_user, user)
  end

  def redirect_authenticated_user(conn, _opts) do
    case conn.assigns[:current_user] do
      nil -> conn
      user -> redirect_to_default(conn, user)
    end
  end

  def require_authenticated_user(conn, _opts) do
    cond do
      not Accounts.browser_auth_enabled?() ->
        conn

      conn.assigns[:current_user] ->
        conn

      true ->
        conn
        |> put_session(:return_to, safe_return_to(conn))
        |> put_flash(:error, "Sign in to continue.")
        |> redirect(to: ~p"/login")
        |> halt()
    end
  end

  def on_mount(:ensure_authenticated, _params, session, socket) do
    user = Accounts.get_session_user(session["user_id"], session["session_version"])

    cond do
      user ->
        {:cont, Phoenix.Component.assign(socket, :current_user, user)}

      not Accounts.browser_auth_enabled?() ->
        {:cont, Phoenix.Component.assign(socket, :current_user, nil)}

      true ->
        socket =
          socket
          |> Phoenix.LiveView.put_flash(:error, "Sign in to continue.")
          |> Phoenix.LiveView.redirect(to: ~p"/login")

        {:halt, socket}
    end
  end

  def log_in_user(conn, user, opts \\ []) do
    return_to = get_session(conn, :return_to)
    destination = Keyword.get(opts, :to) || safe_internal_path(return_to) || default_path(user)

    conn
    |> disconnect_live_socket()
    |> configure_session(renew: true)
    |> clear_session()
    |> put_session(:user_id, user.id)
    |> put_session(:session_version, user.session_version)
    |> put_session(:live_socket_id, live_socket_id(user))
    |> redirect(to: destination)
  end

  def log_out_user(conn) do
    conn
    |> disconnect_live_socket()
    |> configure_session(drop: true)
    |> redirect(to: ~p"/login")
  end

  def live_socket_id(user), do: "user_sessions:#{user.id}:#{user.session_version}"

  def disconnect_user_live_sessions(user) do
    Endpoint.broadcast(live_socket_id(user), "disconnect", %{})
  end

  def default_path(user) do
    case Accounts.default_research_workspace_id(user) do
      nil -> ~p"/control"
      workspace_id -> "/lab/workspaces/#{workspace_id}/studies"
    end
  end

  defp redirect_to_default(conn, user), do: conn |> redirect(to: default_path(user)) |> halt()

  defp disconnect_live_socket(conn) do
    if live_socket_id = get_session(conn, :live_socket_id) do
      Endpoint.broadcast(live_socket_id, "disconnect", %{})
    end

    conn
  end

  defp safe_return_to(%Plug.Conn{method: "GET", request_path: path}), do: safe_internal_path(path)
  defp safe_return_to(_conn), do: nil

  defp safe_internal_path(path) when is_binary(path) do
    uri = URI.parse(path)

    if is_nil(uri.scheme) and is_nil(uri.host) and String.starts_with?(uri.path || "", "/"),
      do: URI.to_string(uri),
      else: nil
  end

  defp safe_internal_path(_path), do: nil
end
