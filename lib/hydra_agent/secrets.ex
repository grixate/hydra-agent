defmodule HydraAgent.Secrets do
  @moduledoc """
  Secret reference helpers.

  Hydra stores references such as environment variable names, not raw secret
  values. Callers receive structured errors that are safe to persist in audit
  logs.
  """

  def fetch_env(env) when is_binary(env) and env != "" do
    case System.get_env(env) do
      nil -> {:error, %{"reason" => "missing_secret_env", "env" => env}}
      value -> {:ok, value}
    end
  end

  def fetch_env(_env), do: {:error, %{"reason" => "missing_secret_env"}}

  def verify_bearer(conn, env) do
    with {:ok, expected} <- fetch_env(env),
         ["Bearer " <> token] <- Plug.Conn.get_req_header(conn, "authorization"),
         true <- Plug.Crypto.secure_compare(token, expected) do
      :ok
    else
      false -> {:error, %{"reason" => "invalid_bearer_token"}}
      [] -> {:error, %{"reason" => "missing_bearer_token"}}
      {:error, error} -> {:error, error}
      _other -> {:error, %{"reason" => "invalid_authorization_header"}}
    end
  end

  def safe_ref(nil), do: nil
  def safe_ref(env) when is_binary(env), do: "env:#{env}"
end
