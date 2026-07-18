import Config

# Do not print debug messages in production
config :logger, level: :info

config :hydra_agent, :allow_capability_policy_fallback, false

# Phoenix compiles the force-SSL plug into the endpoint. Keep this value in
# compile-time production config and repeat it at runtime only as an identical
# endpoint option alongside the dynamic host and secret.
config :hydra_agent, HydraAgentWeb.Endpoint,
  force_ssl: [hsts: true, rewrite_on: [:x_forwarded_proto]],
  cache_static_manifest: "priv/static/cache_manifest.json"

# Runtime production configuration, including reading
# of environment variables, is done on config/runtime.exs.
