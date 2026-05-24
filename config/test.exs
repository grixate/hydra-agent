import Config

# Configure your database
#
# The MIX_TEST_PARTITION environment variable can be used
# to provide built-in test partitioning in CI environment.
# Run `mix help test` for more information.
config :hydra_agent, HydraAgent.Repo,
  url:
    System.get_env(
      "TEST_DATABASE_URL",
      "ecto://#{System.get_env("PGUSER") || System.get_env("USER") || "postgres"}@localhost/hydra_agent_test#{System.get_env("MIX_TEST_PARTITION")}"
    ),
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: 1

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :hydra_agent, HydraAgentWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "9ccmUZex3UI7sfve6vaDSkvBT8XR/Buw67XTvp2GT/+/+WvBElz29oZNACT9qrDl",
  server: false

# Print only warnings and errors during test
config :logger, level: :warning

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

config :phoenix_live_view,
  enable_expensive_runtime_checks: true
