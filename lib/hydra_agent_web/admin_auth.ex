defmodule HydraAgentWeb.AdminAuth do
  @moduledoc """
  Env-backed single-admin authentication for self-hosted browser control planes.
  """

  @session_key "hydra_admin"
  @authenticated_at_key "authenticated_at"
  @rate_limit_table :hydra_admin_auth_rate_limits
  @default_ttl_seconds 28_800
  @default_max_attempts 5
  @default_window_seconds 300

  def session_key, do: @session_key

  def enabled? do
    :hydra_agent
    |> Application.get_env(:browser_auth, [])
    |> Keyword.get(:enabled?, false)
  end

  def config do
    Application.get_env(:hydra_agent, :browser_auth, [])
  end

  def configured? do
    with {:ok, _username} <- expected_username(),
         {:ok, _password} <- expected_password() do
      true
    else
      _error -> false
    end
  end

  def verify(username, password) when is_binary(username) and is_binary(password) do
    with {:ok, expected_username} <- expected_username(),
         {:ok, expected_password} <- expected_password(),
         true <- secure_equal?(username, expected_username),
         true <- secure_equal?(password, expected_password) do
      :ok
    else
      {:error, error} -> {:error, error}
      _other -> {:error, %{"reason" => "invalid_admin_credentials"}}
    end
  end

  def verify(_username, _password), do: {:error, %{"reason" => "invalid_admin_credentials"}}

  def authenticated?(session) when is_map(session) do
    case session[@session_key] || session[:hydra_admin] do
      %{@authenticated_at_key => authenticated_at} when is_integer(authenticated_at) ->
        System.system_time(:second) - authenticated_at <= ttl_seconds()

      %{authenticated_at: authenticated_at} when is_integer(authenticated_at) ->
        System.system_time(:second) - authenticated_at <= ttl_seconds()

      _other ->
        false
    end
  end

  def authenticated?(_session), do: false

  def session_payload(username) do
    %{
      "username" => username,
      @authenticated_at_key => System.system_time(:second)
    }
  end

  def rate_limited?(key) do
    ensure_rate_limit_table()
    now = System.system_time(:second)
    window = rate_limit_window_seconds()

    case :ets.lookup(@rate_limit_table, key) do
      [{^key, count, first_at}] when now - first_at <= window ->
        count >= rate_limit_max_attempts()

      [{^key, _count, _first_at}] ->
        :ets.delete(@rate_limit_table, key)
        false

      [] ->
        false
    end
  end

  def record_failed_attempt(key) do
    ensure_rate_limit_table()
    now = System.system_time(:second)
    window = rate_limit_window_seconds()

    case :ets.lookup(@rate_limit_table, key) do
      [{^key, count, first_at}] when now - first_at <= window ->
        :ets.insert(@rate_limit_table, {key, count + 1, first_at})

      _missing_or_expired ->
        :ets.insert(@rate_limit_table, {key, 1, now})
    end

    :ok
  end

  def clear_failed_attempts(key) do
    ensure_rate_limit_table()
    :ets.delete(@rate_limit_table, key)
    :ok
  end

  def setup_error do
    cond do
      not enabled?() ->
        nil

      missing_username?() ->
        %{"reason" => "missing_admin_username_env", "env" => username_env()}

      missing_password?() ->
        %{"reason" => "missing_admin_password_env", "env" => password_env()}

      true ->
        nil
    end
  end

  defp expected_username do
    username_env()
    |> HydraAgent.Secrets.fetch_env()
  end

  defp expected_password do
    password_env()
    |> HydraAgent.Secrets.fetch_env()
  end

  defp username_env, do: Keyword.get(config(), :username_env, "HYDRA_ADMIN_USERNAME")
  defp password_env, do: Keyword.get(config(), :password_env, "HYDRA_ADMIN_PASSWORD")

  defp missing_username?, do: match?({:error, _error}, expected_username())
  defp missing_password?, do: match?({:error, _error}, expected_password())

  defp ttl_seconds, do: Keyword.get(config(), :session_ttl_seconds, @default_ttl_seconds)

  defp rate_limit_max_attempts,
    do: Keyword.get(config(), :max_failed_attempts, @default_max_attempts)

  defp rate_limit_window_seconds,
    do: Keyword.get(config(), :rate_limit_window_seconds, @default_window_seconds)

  defp ensure_rate_limit_table do
    case :ets.whereis(@rate_limit_table) do
      :undefined ->
        :ets.new(@rate_limit_table, [:named_table, :public, read_concurrency: true])

      _table ->
        @rate_limit_table
    end
  rescue
    ArgumentError -> @rate_limit_table
  end

  defp secure_equal?(left, right) do
    byte_size(left) == byte_size(right) and Plug.Crypto.secure_compare(left, right)
  end
end
