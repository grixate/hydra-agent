# Production Runbooks

These runbooks describe the production operations that can be rehearsed before a
VPS exists. The only missing step is binding them to a real host, domain, and
off-box backup destination.

## Preflight

Before starting or upgrading production:

```bash
scripts/prod-env-check.sh
docker compose -f docker-compose.prod.yml --profile migrate --profile smoke config --quiet
```

Required secrets:

- `SECRET_KEY_BASE`
- `POSTGRES_PASSWORD`
- `HYDRA_API_TOKEN`
- `HYDRA_ADMIN_USERNAME`
- `HYDRA_ADMIN_PASSWORD`
- `HYDRA_BROWSER_WORKER_TOKEN`

Rules:

- API token, admin password, and browser worker token must be different.
- API token and browser worker token should be generated random strings of at
  least 24 characters.
- Admin password should be at least 16 characters.
- `SECRET_KEY_BASE` should be generated with `mix phx.gen.secret`.

## Deploy Or Upgrade

For a fresh VPS install, use the guided installer:

```bash
scripts/install.sh
```

It creates `.env` when missing, generates secrets, validates configuration, runs
migrations, starts the stack, runs smoke, and points the operator to `/setup` for
the browser first-run configuration.

For upgrades or manual deploys:

```bash
scripts/prod-backup.sh
docker compose -f docker-compose.prod.yml --profile migrate run --rm migrate
docker compose -f docker-compose.prod.yml up -d --build
docker compose -f docker-compose.prod.yml --profile smoke run --rm smoke
```

Success criteria:

- `GET /api/health` returns `status=ok`.
- Release smoke returns doctor `status=ok`.
- Browser worker health is `ok`.
- Runtime pressure has no stale leases.

## Local Soak

Run this before tagging a release candidate:

```bash
HYDRA_SOAK_ITERATIONS=60 HYDRA_SOAK_SLEEP_SECONDS=1 scripts/prod-local-soak.sh
```

The soak script builds the production images, migrates a fresh database, starts
the app and browser worker, verifies browser worker action auth rejects
unauthenticated requests, performs repeated health checks, and runs periodic
release smoke checks.

## Doctor Monitoring

For a running instance:

```bash
HYDRA_BASE_URL=https://$PHX_HOST HYDRA_API_TOKEN=$HYDRA_API_TOKEN \
  HYDRA_SMOKE_FAIL_ON_WARNING=true scripts/prod-doctor-check.sh
```

Warnings should page an operator in production because the doctor already
distinguishes optional missing setup from hard errors. Runtime pressure warnings
mean stale leased work should be recovered before more autonomous work starts.

Systemd templates live in `ops/systemd`:

- `hydra-doctor.service`
- `hydra-doctor.timer`
- `hydra-backup.service`
- `hydra-backup.timer`

## Backup

Create a local backup:

```bash
scripts/prod-backup.sh
```

Prove restore:

```bash
scripts/prod-restore-smoke.sh backups/hydra-agent-YYYYMMDDTHHMMSSZ.sql
```

Production policy:

- Run backups daily at minimum.
- Copy backups off-box after creation.
- Keep at least seven daily backups and four weekly backups.
- Run restore smoke after schema changes and at least monthly.
- Set `HYDRA_BACKUP_CONFIGURED=true` only after the off-box schedule exists.

## Token Rotation

Rotation order:

1. Generate new `HYDRA_API_TOKEN`, `HYDRA_ADMIN_PASSWORD`, and
   `HYDRA_BROWSER_WORKER_TOKEN` values.
2. Update the production env file.
3. Restart the app and browser worker.
4. Run:

```bash
scripts/prod-env-check.sh
docker compose -f docker-compose.prod.yml up -d app browser-worker
scripts/prod-token-rotation-check.sh
```

5. Update any API clients with the new API token.

## Rollback

Rollback is allowed only after a backup exists.

```bash
scripts/prod-backup.sh
docker compose -f docker-compose.prod.yml down
git checkout <previous-release>
docker compose -f docker-compose.prod.yml --profile migrate run --rm migrate
docker compose -f docker-compose.prod.yml up -d --build
docker compose -f docker-compose.prod.yml --profile smoke run --rm smoke
```

If the database migration itself caused damage, restore the last known-good
backup into a fresh database first:

```bash
scripts/prod-restore-smoke.sh backups/hydra-agent-known-good.sql
```

## Incident Triage

Use this order:

1. `docker compose -f docker-compose.prod.yml ps`
2. `docker compose -f docker-compose.prod.yml logs app browser-worker postgres`
3. `scripts/prod-doctor-check.sh`
4. Runtime Operations page for stale leases, approvals, incidents, and provider
   pressure.
5. `docker compose -f docker-compose.prod.yml --profile smoke run --rm smoke`

Common actions:

- Doctor `browser_worker` error: check token env, worker health, and worker logs.
- Runtime pressure warning: inspect stale run or simulation leases in Runtime
  Operations before accepting more autonomous work.
- Backup warning: do not upgrade until backup schedule and off-box copy are
  confirmed.
- Auth error: verify env names, restart app, and rerun doctor.

## VPS-Only Work

These cannot be completed locally:

- DNS and TLS issuance against the real `PHX_HOST`.
- Host firewall and SSH hardening.
- Off-box backup destination credentials and retention policy.
- External uptime monitor configuration.
- Real provider webhook registration against the public domain.
