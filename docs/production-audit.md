# Production Readiness Audit

Audit date: 2026-05-28  
Scope: no-VPS production-readiness audit for the current Hydra Agent worktree.  
Audit type: evidence matrix with production AppSec depth.
Last updated: 2026-05-28 after deeper bug-hunt remediation.

## Executive Summary

Verdict: **Ready for first VPS deployment**.

Hydra's application, runtime, simulation system, production images, CI gates,
auth posture, browser-worker isolation, doctor checks, release smoke, and local
soak path are in strong shape for a first VPS deployment rehearsal.

The initial audit found no P0 blockers and one P1 production risk: restore smoke
could race Postgres startup. A deeper bug hunt also found that terminal
simulation records could be mutated by late lifecycle actions or stale workers.
Both issues have been fixed and reverified locally.

No active P0 or P1 findings remain in the no-VPS scope. Remaining work is
limited to VPS/external-provider setup plus the P3 local buildx warning.

## Findings

| ID | Severity | Finding | Impact | Evidence | Recommended Fix |
|---|---:|---|---|---|---|
| PA-002 | P3 polish | Local Docker emits `Docker Compose requires buildx plugin to be installed`. | Does not block builds because classic builder completed successfully, but it adds noise and may hide future build warnings. | Production build and soak logs showed the warning while still succeeding. | Install the Compose buildx plugin locally and document it in setup prerequisites. |

No active P0 or P1 findings remain.

### Resolved Findings

| ID | Original Severity | Finding | Fix | Verification |
|---|---:|---|---|---|
| PA-001 | P1 production risk | Restore smoke raced Postgres startup before `dropdb`. | Added explicit Postgres and browser-worker readiness waits to `scripts/prod-restore-smoke.sh`. | Pass: `scripts/prod-restore-smoke.sh backups/audit-smoke.sql` restored the backup, ran migrations, passed app health, passed release smoke, and cleaned up. |
| PA-003 | P1 production risk | Terminal simulations could be mutated by late pause/cancel/fail actions or stale workers. | Reload lifecycle targets, guard legal transitions, lock tick recording with `FOR UPDATE`, and reject new ticks for terminal simulations. | Pass: `mix test test/hydra_agent/simulation_test.exs` and controller/live simulation tests. |
| PA-004 | P2 hardening | Doctor systemd template pointed at `http://127.0.0.1:4000`, but prod Compose keeps the app internal behind Caddy. | Removed the unsafe script default and made the systemd unit derive `HYDRA_BASE_URL=https://$PHX_HOST`. | Pass: `scripts/prod-doctor-check.sh` succeeds against an explicit local fixture URL and fails closed when no base URL is supplied. |

## Evidence Matrix

| Domain | Check | Evidence | Pass Criteria | Result | Severity / Follow-up |
|---|---|---|---|---|---|
| Build / CI | Elixir precommit gate | `mix precommit` | Compile warnings-as-errors, format, and tests pass. | Pass: 434 tests, 0 failures after bug-hunt fixes. | None |
| Build / CI | Full CI gate | `mix ci` | Format check, compile warnings-as-errors, test coverage, Credo, Sobelow, and Mix audit pass. | Pass: 432 tests, 0 failures; coverage 72.51%; Credo clean; Sobelow clean; Mix audit clean. | None |
| Build / CI | Browser worker dependency audit | `npm --prefix services/browser-worker audit --audit-level=high` | No high or critical npm vulnerabilities. | Pass: 0 vulnerabilities. | None |
| Build / CI | Script syntax | `bash -n scripts/*.sh` | All shell scripts parse. | Pass. | None |
| Build / CI | Browser worker JS syntax | `node --check services/browser-worker/server.js` | Node parses worker source. | Pass. | None |
| Build / CI | GitHub Actions workflow lint | `docker run --rm -v "$PWD:/repo" -w /repo rhysd/actionlint:1.7.7 .github/workflows/ci.yml` | Workflow lints cleanly. | Pass. | None |
| Deployment | Production env shape | `scripts/prod-env-check.sh` with production-like env. | Required secrets exist, token lengths are acceptable, API/worker/admin secrets differ, Compose config validates. | Pass: `Production env shape is valid for docker-compose.prod.yml`. | None |
| Deployment | Production Compose config | `docker compose -f docker-compose.prod.yml --profile migrate --profile smoke config --quiet` through env check. | Compose renders without errors. | Pass. | None |
| Deployment | Production image build | `docker compose -f docker-compose.prod.yml --profile migrate --profile smoke build browser-worker app migrate smoke` | App, migrate, smoke, and browser-worker images build. | Pass. | P3: local buildx warning only. |
| Deployment | Fresh migration | `docker compose -f docker-compose.prod.yml --profile migrate run --rm migrate` on fresh volume. | All migrations apply to a fresh Postgres volume. | Pass. | None |
| Deployment | Release smoke | `docker compose -f docker-compose.prod.yml --profile smoke run --rm smoke` | Doctor returns `status=ok`; `HYDRA_SMOKE_FAIL_ON_WARNING=true` fails on warnings. | Pass: doctor `ok`, 10 checks total. | None |
| Deployment | Container cleanup | `docker ps --filter name=hydra-agent2 --format '{{.Names}}'` after cleanup. | No audit Compose containers remain running. | Pass: no output. | None |
| Security | Public health endpoint and protected API | `mix ci`; `test/hydra_agent_web/plugs/api_auth_test.exs`; `HydraAgentWeb.Plugs.ApiAuth`. | `/api/health` remains public; protected API rejects missing/wrong bearer; missing token env fails closed. | Pass. | None |
| Security | Browser admin auth | `mix ci`; `test/hydra_agent_web/plugs/admin_auth_test.exs`; `HydraAgentWeb.Plugs.AdminAuth`. | Browser management routes require env-backed login and fail closed when admin envs are missing. | Pass. | None |
| Security | Browser-worker action auth | `scripts/prod-local-soak.sh`; `HydraAgent.Browser`; `services/browser-worker/server.js`. | Unauthenticated worker action requests return 401; app signs worker actions with bearer token. | Pass: local soak verified unauthenticated action rejection. | None |
| Security | Secret handling | `HydraAgent.Secrets`; connector/MCP tests in `mix ci`. | Raw secrets are fetched from env refs and secret-like inline MCP config is rejected. | Pass. | None |
| Security | Dangerous tool policy | `HydraAgent.Runtime.ToolPolicy`; `HydraAgent.Runtime.Authorizer`; `mix ci`. | Dangerous side effects cannot be configured without approval and authorization gates route sensitive tools to approval. | Pass. | None |
| Security | Webhook secret verification | `HydraAgent.Rooms.verify_telegram_secret/2`; room/Telegram tests in `mix ci`. | Telegram secret header is verified when `secret_env` is configured. | Pass. | None |
| Runtime | Stale run step detection and recovery | Runtime tests in `mix ci`; `HydraAgent.Runtime.recover_stale_steps/2`; doctor runtime pressure check. | Stale leases are detectable and recoverable; stale pressure appears in doctor. | Pass. | None |
| Runtime | Cancellation and approvals | Runtime runner tests in `mix ci`; Runtime Operations tests. | Canceled runs stop in-flight steps; dangerous steps wait for approval. | Pass. | None |
| Simulation | Durable leases and recovery | Simulation tests in `mix ci`; `HydraAgent.Simulation.recover_running_simulations/1`. | Stale running simulations are recoverable. | Pass. | None |
| Simulation | Budget blocking and reservation release | Simulation tests in `mix ci`; `HydraAgent.Budgets.release_simulation_reservation/3`. | Budget exhaustion moves simulation to `budget_blocked`; terminal statuses release/cancel/exhaust reservations. | Pass. | None |
| Simulation | Replay/export/report tools | Simulation V2 tool tests in `mix ci`. | Duplicate, replay, export, cancel, and report tool paths operate through durable state. | Pass. | None |
| Database | Workspace-scoped schema posture | Migration/source review plus `mix ci`. | New runtime/simulation/connector tables include workspace scoping where appropriate; global tables are intentional. | Pass. | None |
| Backup / Restore | Backup creation | `scripts/prod-backup.sh backups/audit-smoke.sql` against running production Compose stack. | Backup file is non-empty. | Pass: `backups/audit-smoke.sql` written, 197628 bytes. | None |
| Backup / Restore | Restore proof | `scripts/prod-restore-smoke.sh backups/audit-smoke.sql`. | Fresh restore runs, migrations apply, app health passes, release smoke passes. | Pass: backup restored, migrations were current, app health passed, doctor smoke returned `status=ok`, and Compose cleanup removed containers/volume/network. | None |
| Observability | Doctor coverage | Release smoke output; `HydraAgent.Doctor`. | Doctor covers DB, migrations, auth envs, backup marker, tool registry, agent packs, OTP processes, runtime pressure, and browser worker. | Pass. | None |
| Observability | Telemetry surfaces | `HydraAgentWeb.Telemetry`; simulation/browser telemetry source review. | Core Phoenix/Repo/VM metrics plus browser and simulation events are registered. | Pass. | None |
| Operations | Local soak | `HYDRA_SOAK_ITERATIONS=10 HYDRA_SOAK_SLEEP_SECONDS=0 scripts/prod-local-soak.sh`. | Fresh stack, migrations, smoke, unauthenticated worker rejection, health loop, and periodic smoke pass. | Pass: 10 health checks plus periodic smoke checks. | None |
| Operations | Token rotation proof | `scripts/prod-token-rotation-check.sh` against running production Compose stack. | App healthy, smoke green, stale bearer token rejected. | Pass. | None |
| Operations | Doctor monitor script | `HYDRA_BASE_URL=http://127.0.0.1:48765 HYDRA_API_TOKEN=test scripts/prod-doctor-check.sh`; source review of `ops/systemd/hydra-doctor.service`. | Script requires explicit base URL, calls `/api/v1/doctor` with bearer auth, and fails on error/warning when configured. | Pass: fixture doctor returned `global doctor status: ok`; systemd template now targets `https://$PHX_HOST` instead of internal app port. | VPS/external monitor follow-up for real domain only |
| Documentation | Runbooks and readiness docs | `docs/production-readiness.md`, `docs/production-runbooks.md`, `docs/v4-productization.md`. | Operator can find envs, deploy, rollback, backup, restore, token rotation, incident triage, and VPS-only gaps. | Pass. | None |

## VPS-Only Items

These were intentionally not tested because they require a real host, public
domain, or external provider/storage:

- DNS and TLS issuance for the real `PHX_HOST`.
- Host firewall, SSH hardening, and package baseline.
- Installing `ops/systemd` timers on a real host.
- Off-box backup copy, retention, and restore from remote storage.
- External uptime and doctor monitor configuration.
- Real provider webhook registration against the public HTTPS domain.
- Long-running production soak under real provider credentials and network
  conditions.

## Verdict

Hydra is **ready for first VPS deployment** within the no-VPS audit scope.

The restore proof command passed after remediation:

```bash
PHX_HOST=hydra.example.test \
POSTGRES_PASSWORD=postgres-ci-password \
SECRET_KEY_BASE=4dW2dA59kUjS45Kz6Km7PkUzyTNjCYR4nSLQm5egT1hoNdM1H99cE4gtKUiP1/3U \
HYDRA_API_TOKEN=ci-api-token-ci-api-token \
HYDRA_ADMIN_USERNAME=admin \
HYDRA_ADMIN_PASSWORD=admin-password-for-ci \
HYDRA_BROWSER_WORKER_TOKEN=ci-browser-worker-token-ci \
HYDRA_BACKUP_CONFIGURED=true \
HYDRA_SMOKE_FAIL_ON_WARNING=true \
scripts/prod-restore-smoke.sh backups/audit-smoke.sql
```

The remaining gaps are VPS/external-service operations rather than application
production-readiness blockers.
