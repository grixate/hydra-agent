# Production Readiness Status

This is the current no-VPS production-readiness boundary.

## Done Locally

- Release build runs as a non-root container.
- Caddy/Postgres/app/browser-worker production Compose stack validates.
- Production app health check exists at `/api/health`.
- Browser and API auth fail closed in production.
- Browser worker action requests require a separate bearer token.
- Browser worker has bounded sessions, body size, action timeout, idle cleanup,
  and screenshot payload size.
- Doctor checks database connectivity, migrations, auth envs, backup marker,
  tool registry, agent packs, OTP processes, runtime pressure, browser worker
  health, providers, connectors, automations, Telegram, and MCP readiness.
- Release smoke runs doctor and can fail on warnings.
- Backup and restore-smoke scripts exist.
- Local production soak script exists.
- Token rotation proof script exists.
- CI runs Elixir tests, coverage, Credo, Sobelow, Mix audit, browser-worker npm
  audit, Compose validation, Caddy validation, production Compose smoke, and
  deployment proof artifact upload.
- Simulation engine has durable state, budget reservations, leases, recovery,
  budget-blocked terminal state, reports, replay/export tools, and telemetry.

## Must Stay Green Before A Release

```bash
mix precommit
mix ci
npm --prefix services/browser-worker audit --audit-level=high
node --check services/browser-worker/server.js
bash -n scripts/*.sh
PHX_HOST=hydra.example.test \
POSTGRES_PASSWORD=postgres-ci-password \
SECRET_KEY_BASE=4dW2dA59kUjS45Kz6Km7PkUzyTNjCYR4nSLQm5egT1hoNdM1H99cE4gtKUiP1/3U \
HYDRA_API_TOKEN=ci-api-token-ci-api-token \
HYDRA_ADMIN_USERNAME=admin \
HYDRA_ADMIN_PASSWORD=admin-password-for-ci \
HYDRA_BROWSER_WORKER_TOKEN=ci-browser-worker-token-ci \
HYDRA_BACKUP_CONFIGURED=true \
HYDRA_SMOKE_FAIL_ON_WARNING=true \
scripts/prod-env-check.sh
```

For release candidates, additionally run:

```bash
HYDRA_SOAK_ITERATIONS=60 HYDRA_SOAK_SLEEP_SECONDS=1 scripts/prod-local-soak.sh
```

## Remaining VPS-Only Items

- Provision host and firewall.
- Point DNS to the host and validate Caddy TLS issuance.
- Install the systemd timer templates from `ops/systemd`.
- Configure off-box backup copy and retention.
- Configure external uptime and doctor monitors.
- Register real provider webhooks against the public domain.
- Run a real restore drill from off-box storage.

Nothing in this list requires a product architecture change; it is deployment
and operations proof on real infrastructure.
