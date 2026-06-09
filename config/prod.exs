import Config

# Do not print debug messages in production
config :logger, level: :info

config :hydra_agent, :allow_capability_policy_fallback, false

config :hydra_agent, HydraAgentWeb.Endpoint,
  force_ssl: [hsts: true, rewrite_on: [:x_forwarded_proto]]

# Runtime production configuration, including reading
# of environment variables, is done on config/runtime.exs.
