import Config

# config/runtime.exs is executed for all environments, including
# during releases. It is executed after compilation and before the
# system starts, so it is typically used to load production configuration
# and secrets from environment variables or elsewhere. Do not define
# any compile-time configuration in here, as it won't be applied.
# The block below contains prod specific runtime configuration.

# ## Using releases
#
# If you use `mix release`, you need to explicitly enable the server
# by passing the PHX_SERVER=true when you start it:
#
#     PHX_SERVER=true bin/hydra_agent start
#
# Alternatively, you can use `mix phx.gen.release` to generate a `bin/server`
# script that automatically sets the env var above.
if System.get_env("PHX_SERVER") do
  config :hydra_agent, HydraAgentWeb.Endpoint, server: true
end

if browser_worker_url = System.get_env("HYDRA_BROWSER_WORKER_URL") do
  config :hydra_agent, :browser_worker_url, browser_worker_url
end

if config_env() == :prod do
  database_url =
    System.get_env("DATABASE_URL") ||
      raise """
      environment variable DATABASE_URL is missing.
      For example: ecto://USER:PASS@HOST/DATABASE
      """

  maybe_ipv6 = if System.get_env("ECTO_IPV6") in ~w(true 1), do: [:inet6], else: []

  config :hydra_agent, HydraAgent.Repo,
    # ssl: true,
    url: database_url,
    pool_size: String.to_integer(System.get_env("POOL_SIZE") || "10"),
    socket_options: maybe_ipv6

  # The secret key base is used to sign/encrypt cookies and other secrets.
  # A default value is used in config/dev.exs and config/test.exs but you
  # want to use a different value for prod and you most likely don't want
  # to check this value into version control, so we use an environment
  # variable instead.
  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      raise """
      environment variable SECRET_KEY_BASE is missing.
      You can generate one by calling: mix phx.gen.secret
      """

  host = System.get_env("PHX_HOST") || "example.com"
  port = String.to_integer(System.get_env("PORT") || "4000")

  config :hydra_agent, :dns_cluster_query, System.get_env("DNS_CLUSTER_QUERY")

  api_token_env = System.get_env("HYDRA_API_TOKEN_ENV") || "HYDRA_API_TOKEN"
  api_auth_disabled? = System.get_env("HYDRA_API_AUTH_REQUIRED") in ~w(false 0)
  browser_auth_disabled? = System.get_env("HYDRA_BROWSER_AUTH_REQUIRED") in ~w(false 0)

  browser_worker_token_env =
    System.get_env("HYDRA_BROWSER_WORKER_TOKEN_ENV") || "HYDRA_BROWSER_WORKER_TOKEN"

  browser_worker_auth_disabled? =
    System.get_env("HYDRA_BROWSER_WORKER_AUTH_REQUIRED") in ~w(false 0)

  config :hydra_agent, :api_auth,
    enabled?: not api_auth_disabled?,
    token_env: api_token_env

  config :hydra_agent, :browser_worker,
    auth_required?: not browser_worker_auth_disabled?,
    token_env: browser_worker_token_env

  config :hydra_agent, :browser_auth,
    enabled?: not browser_auth_disabled?,
    username_env: System.get_env("HYDRA_ADMIN_USERNAME_ENV") || "HYDRA_ADMIN_USERNAME",
    password_env: System.get_env("HYDRA_ADMIN_PASSWORD_ENV") || "HYDRA_ADMIN_PASSWORD",
    session_ttl_seconds:
      String.to_integer(System.get_env("HYDRA_ADMIN_SESSION_TTL_SECONDS") || "28800"),
    max_failed_attempts:
      String.to_integer(System.get_env("HYDRA_ADMIN_MAX_FAILED_ATTEMPTS") || "5"),
    rate_limit_window_seconds:
      String.to_integer(System.get_env("HYDRA_ADMIN_RATE_LIMIT_WINDOW_SECONDS") || "300")

  config :hydra_agent, HydraAgentWeb.Endpoint,
    url: [host: host, port: 443, scheme: "https"],
    http: [
      # Enable IPv6 and bind on all interfaces.
      # Set it to  {0, 0, 0, 0, 0, 0, 0, 1} for local network only access.
      # See the documentation on https://hexdocs.pm/plug_cowboy/Plug.Cowboy.html
      # for details about using IPv6 vs IPv4 and loopback vs public addresses.
      ip: {0, 0, 0, 0, 0, 0, 0, 0},
      port: port
    ],
    secret_key_base: secret_key_base

  # ## SSL Support
  #
  # To get SSL working, you will need to add the `https` key
  # to your endpoint configuration:
  #
  #     config :hydra_agent, HydraAgentWeb.Endpoint,
  #       https: [
  #         ...,
  #         port: 443,
  #         cipher_suite: :strong,
  #         keyfile: System.get_env("SOME_APP_SSL_KEY_PATH"),
  #         certfile: System.get_env("SOME_APP_SSL_CERT_PATH")
  #       ]
  #
  # The `cipher_suite` is set to `:strong` to support only the
  # latest and more secure SSL ciphers. This means old browsers
  # and clients may not be supported. You can set it to
  # `:compatible` for wider support.
  #
  # `:keyfile` and `:certfile` expect an absolute path to the key
  # and cert in disk or a relative path inside priv, for example
  # "priv/ssl/server.key". For all supported SSL configuration
  # options, see https://hexdocs.pm/plug/Plug.SSL.html#configure/1
  #
  # We also recommend setting `force_ssl` in your endpoint, ensuring
  # no data is ever sent via http, always redirecting to https:
  #
  #     config :hydra_agent, HydraAgentWeb.Endpoint,
  #       force_ssl: [hsts: true]
  #
  # Check `Plug.SSL` for all available options in `force_ssl`.
end
