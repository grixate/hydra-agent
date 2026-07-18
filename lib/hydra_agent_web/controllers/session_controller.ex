defmodule HydraAgentWeb.SessionController do
  use HydraAgentWeb, :controller

  alias HydraAgent.Accounts
  alias HydraAgentWeb.{LoginRateLimiter, UserAuth}

  def new(conn, _params), do: render(conn, :new, layout: false, page_title: "Sign in")

  def create(conn, %{"session" => %{"email" => email, "password" => password}}) do
    key = LoginRateLimiter.key(conn, email)

    if LoginRateLimiter.allowed?(key) do
      case Accounts.authenticate(email, password) do
        {:ok, user} ->
          LoginRateLimiter.clear(key)
          UserAuth.log_in_user(conn, user)

        {:error, :invalid_credentials} ->
          LoginRateLimiter.record_failure(key)
          invalid_credentials(conn, email, :unprocessable_entity)
      end
    else
      conn
      |> put_resp_header("retry-after", "900")
      |> invalid_credentials(email, :too_many_requests)
    end
  end

  def create(conn, _params) do
    conn
    |> put_flash(:error, "Enter your email and password.")
    |> put_status(:unprocessable_entity)
    |> render(:new, layout: false, page_title: "Sign in")
  end

  def delete(conn, _params), do: UserAuth.log_out_user(conn)

  def security(conn, _params), do: render(conn, :security, page_title: "Account security")

  def update_password(
        conn,
        %{
          "security" => %{
            "current_password" => current,
            "new_password" => new_password,
            "new_password_confirmation" => confirmation
          }
        }
      ) do
    if new_password == confirmation do
      change_password(conn, current, new_password)
    else
      password_error(conn, "New password confirmation does not match.")
    end
  end

  def update_password(conn, _params), do: password_error(conn, "Complete every password field.")

  defp change_password(conn, current, new_password) do
    case Accounts.change_password(conn.assigns.current_user, current, new_password) do
      {:ok, user} ->
        conn
        |> put_flash(:info, "Password changed. Other browser sessions have been signed out.")
        |> UserAuth.log_in_user(user, to: ~p"/account/security")

      {:error, :invalid_current_password} ->
        password_error(conn, "Current password is incorrect.")

      {:error, :password_too_short} ->
        password_error(conn, "New passwords must contain at least 12 characters.")

      {:error, _reason} ->
        password_error(conn, "The password could not be changed. Try again.")
    end
  end

  defp invalid_credentials(conn, email, status) do
    conn
    |> put_flash(:error, "Email or password is incorrect.")
    |> put_status(status)
    |> render(:new, layout: false, email: email, page_title: "Sign in")
  end

  defp password_error(conn, message) do
    conn
    |> put_flash(:error, message)
    |> put_status(:unprocessable_entity)
    |> render(:security, page_title: "Account security")
  end
end
