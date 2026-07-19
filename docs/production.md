# Production operations

Hydra is designed to run behind a TLS-terminating reverse proxy with a dedicated
PostgreSQL database. Production browser authentication and API authentication
fail closed.

## Required environment

- `PHX_HOST`
- `SECRET_KEY_BASE`
- `POSTGRES_PASSWORD`
- `HYDRA_API_TOKEN`
- `HYDRA_BACKUP_KEY_FILE` (a host path containing a high-entropy backup passphrase)

Required only on the first boot:

- `HYDRA_BOOTSTRAP_ADMIN_EMAIL`
- `HYDRA_BOOTSTRAP_ADMIN_PASSWORD` (at least 12 characters)

Required before a controlled pilot or public deployment:

- `HYDRA_OPERATOR_NAME`
- `HYDRA_SUPPORT_EMAIL`
- `HYDRA_SECURITY_EMAIL`
- `HYDRA_PRIVACY_URL`
- `HYDRA_RETENTION_SUMMARY`
- `HYDRA_RETENTION_SUMMARY_RU` (optional localized retention text)

Hydra displays these values under Settings → Privacy & data flow and marks the
operator notice incomplete when any is absent. They are deployment-owned public
copy, not secrets.

Generate secrets with a password manager or `mix phx.gen.secret`; do not commit
them. The bootstrap password is read from the environment and only a PBKDF2
verifier is stored. Remove the two bootstrap variables after the first admin is
created.

Provider credentials are injected into the application container, never baked
into an image. Compose passes exported `TAVILY_API_KEY`, `OPENAI_API_KEY`,
`ANTHROPIC_API_KEY`, `DEEPSEEK_API_KEY`, `MOONSHOT_API_KEY`, and `QWEN_API_KEY`
values. For a provider configuration that names another environment variable,
create a mode-0600 provider file outside the repository and set
`HYDRA_PROVIDER_ENV_FILE=/absolute/path/to/provider.env`. The default optional
file is `.env.providers`, which is ignored by Git and the Docker build context.
Before enabling a route for participants, run the live structured-output probe
and failure matrix in `docs/provider-staging.md`. A mock provider or ambient
local Codex CLI login is not production-provider evidence.

MCP process and credential access is disabled unless the deployment operator
opens it explicitly. `HYDRA_MCP_STDIO_EXECUTABLES` is a comma-separated list of
exact executable tokens accepted in stdio server records;
`HYDRA_MCP_ENV_REFS` is the comma-separated list of environment-variable names
that any MCP transport may reference. Prefer dedicated, reviewed MCP binaries
or wrapper entrypoints. Do not allowlist general shells, language runtimes, or
package launchers such as `sh`, `node`, or `npx`, because their arguments can
turn an executable grant into arbitrary code execution. Expose only
MCP-specific credentials, never deployment credentials such as `DATABASE_URL`,
`SECRET_KEY_BASE`, or the global API token. Stdio children receive a cleared
environment plus a minimal non-secret runtime baseline and the declared,
allowlisted references.

Remote HTTP and SSE MCP endpoints must use public HTTPS. Hydra validates every
resolved address, pins one validated address while retaining the original TLS
hostname, disables redirects, retries, and compression, and caps responses at
1 MB. Existing plain-HTTP, private-network, unallowlisted stdio, or
unallowlisted env-backed records remain inert until an operator replaces or
explicitly permits their configuration. `trust_level` is descriptive metadata;
it is not an execution authorization boundary.

Provision additional workspace users without placing a password in shell
history. Set a temporary secret environment variable, then run:

```sh
bin/hydra_agent eval 'HydraAgent.Release.provision_workspace_user("researcher@example.com", "HYDRA_NEW_USER_PASSWORD", "workspace-slug", "researcher")'
```

Supported roles are `viewer`, `researcher`, `admin`, and `owner`. Remove the
temporary password variable immediately afterward. Existing users keep their
password verifier; the command adds only the new workspace membership.

Users can change their own password under Account → Security; that invalidates
all other browser sessions. Operators can recover an account without putting a
password in shell history:

```sh
bin/hydra_agent eval 'HydraAgent.Release.reset_user_password("researcher@example.com", "HYDRA_NEW_USER_PASSWORD")'
```

The environment bearer token is the break-glass global credential. Routine
integrations should receive a hashed, expiring, revocable workspace token. The
raw value is returned once:

```sh
bin/hydra_agent eval 'HydraAgent.Release.issue_api_token("report-reader", "workspace-slug", ["read"], 30)'
```

Revoke it using the non-secret prefix returned at issuance:

```sh
bin/hydra_agent eval 'HydraAgent.Release.revoke_api_token("hydra_prefix")'
```

Database-backed workspace tokens are not operator credentials. Even when they
include `write`, they cannot configure providers, credential pools, MCP
servers, tool policies, connector credentials, or channel bindings, and they
cannot execute or approve dangerous runtime work. Use the environment token or
the authenticated operator interface for those deployment-affecting actions.

## Deploy

1. Back up PostgreSQL.
2. Build an immutable image from the reviewed commit.
3. Run `HydraAgent.Release.migrate()` using the new image.
4. Start the application only after the migration exits successfully.
5. Wait for `/readyz` to report both `database` and `jobs` as ready.
6. Sign in, confirm workspace membership boundaries, and run a tiny synthetic
   study before directing users to the release.

`docker compose -f docker-compose.prod.yml up -d --build` encodes that order.
The application container runs as an unprivileged user with a read-only root
filesystem, no Linux capabilities, and a writable in-memory `/tmp` only.
Compose also sets overridable CPU, memory, PID, shared-memory, temporary-storage,
and JSON log-rotation limits for every service. Size these against measured
production load; limits are guardrails, not capacity planning.

Compose binds the application to `127.0.0.1` by default so only a reverse proxy
on the same host can reach the clear-text upstream. Set `HYDRA_BIND_ADDRESS`
only when the proxy uses a separately protected interface or container network;
do not publish the upstream port directly to the internet.

The browser worker is built from `services/browser-worker/Dockerfile` with an
exact Playwright package lock matching its browser image. It runs as a non-root
user with a read-only filesystem, dropped capabilities, bounded memory, PIDs,
concurrency, output, and session lifetime. Separate control and egress networks
keep it away from PostgreSQL. Every HTTP, redirect, subresource, and WebSocket
request is forced through a bounded loopback proxy. That proxy resolves every
new destination, rejects the complete answer set if any address is non-global,
and connects Chromium to the selected numeric IP while retaining the original
HTTP Host and TLS SNI. Redirects and new WebSocket/CONNECT tunnels are therefore
revalidated without a DNS-resolution race. Only ports 80/443 are allowed by
default. Use
`HYDRA_BROWSER_ALLOWED_HOSTS` for a stricter deployment-wide hostname allowlist.
Never enable `HYDRA_BROWSER_ALLOW_PRIVATE_NETWORKS` in a public deployment.

The reverse proxy must set `x-forwarded-proto: https` and overwrite
`x-forwarded-for` with the connecting client address. Hydra trusts forwarded
client addresses only from loopback peers by default; set
`HYDRA_TRUSTED_PROXY_IPS` to an explicit comma-separated IP list when the proxy
uses another protected interface. Never include an internet-facing address or
an unrestricted network. Hydra redirects plain HTTP and emits HSTS in
production. Liveness and readiness contain no tenant data. `/api/metrics` and
`/api/metrics/openmetrics` are protected by the API bearer token. Point the
external telemetry collector at the OpenMetrics route and load
`ops/prometheus/hydra-alerts.yml` into Prometheus-compatible alerting.
`ops/prometheus/prometheus.yml.example` shows a bearer-token-file scrape setup;
copy it into operator-owned configuration and replace the example hostname.

## Data and jobs

- PostgreSQL is the system of record for studies, evidence, simulation inputs,
  snapshots, forecasts, memberships, research runs, and Oban jobs.
- Provider research is queued only after its run ledger is committed.
- Simulation inputs are snapshotted before execution; source text is excluded.
- Public URL ingestion pins a validated public DNS answer for the TLS request,
  disables redirects, and caps response size.
- The current aggregate simulator performs zero provider calls and enforces its
  stored `$0.00` provider budget again before publication.

## Backup and restore

The production Compose stack runs `ops/backup/backup-loop` every 24 hours by
default. It writes encrypted, permission-restricted archives to
`HYDRA_BACKUP_DIR` and prunes archives after `HYDRA_BACKUP_RETENTION_DAYS`.
Compose uses the managed `hydra_agent_backups` volume by default. For a real
deployment, set `HYDRA_BACKUP_VOLUME=/prepared/off-host/path` to use storage
outside the application host's lifecycle, and make that directory writable by
the backup image's unprivileged `postgres` user (UID 70).
The backup container runs without Linux capabilities and receives the
passphrase as a read-only file, never as a command-line argument.
Its unencrypted custom dump exists only on a bounded in-memory `/tmp`; set
`HYDRA_BACKUP_TMPFS_SIZE` and `HYDRA_BACKUP_MEMORY_LIMIT` above the largest
measured compressed logical dump or the backup will deliberately fail closed.

Each backup is written as a complete temporary PostgreSQL custom archive and
validated with `pg_restore --list` before encryption. The encrypted round trip
is checked before publication and again by the recurring loop. A dump,
encryption, or verification failure exits the backup container rather than
publishing a success path. `ops/backup/check-backup` performs the same
non-destructive structural check on demand; a disposable database restore is
still required to prove application-level recovery.

Run an additional encrypted logical backup before every schema deployment:

```sh
HYDRA_BACKUP_DIR=/secure/off-host/path \
HYDRA_BACKUP_KEY_FILE=/run/secrets/hydra_backup_key \
ops/backup/backup
```

Verify an archive by restoring it into a disposable database. The verifier
refuses database names that do not include `restore_test` or `backup_verify`:

```sh
createdb hydra_agent_restore_test
RESTORE_TEST_DATABASE_URL=ecto://hydra@localhost/hydra_agent_restore_test \
HYDRA_BACKUP_KEY_FILE=/run/secrets/hydra_backup_key \
ops/backup/verify-backup /secure/off-host/path/hydra-agent-*.dump.enc
```

For the release gate, run the complete rehearsal against a filesystem that is
different from the application filesystem and survives loss of the host:

```sh
HYDRA_OFF_HOST_CONFIRMED=1 \
DATABASE_URL="$DATABASE_URL" \
RESTORE_TEST_DATABASE_URL="$RESTORE_TEST_DATABASE_URL" \
HYDRA_BACKUP_DIR=/mounted/off-host/release-evidence \
HYDRA_BACKUP_KEY_FILE=/run/secrets/hydra_backup_key \
ops/backup/off-host-rehearsal
```

The rehearsal refuses same-filesystem storage and reports the archive SHA-256,
source/target devices, migration count, required core tables, and non-sensitive
record counts. Keep its output with the candidate release evidence.

Keep database backups separate from application images and apply the same
retention and access policy as workspace evidence.

## Rollback

Application releases are forward-migrated. If a release fails before a data
write, restore the previous image. If it has written through a new schema,
stop writers and restore the pre-deploy backup; do not guess at a destructive
down migration. Record the image digest, migration version, and restore point
in the incident trail.

## Release checks

- `mix precommit`
- `mix test --cover` (the checked-in floor prevents coverage regression)
- `docker build .`
- `docker build services/browser-worker`
- `docker build ops/backup`
- `HYDRA_IMAGE=<reviewed-image> ops/release-smoke`
- `HYDRA_IMAGE=<reviewed-image> HYDRA_BROWSER_WORKER_IMAGE=<worker-image> HYDRA_BACKUP_IMAGE=<backup-image> ops/compose-smoke`
- authenticated desktop and 390px mobile smoke paths
- cross-workspace read and mutation denial
- restart with queued research and simulation jobs
- backup restore rehearsal for schema-changing releases
- live provider probe for every enabled route and fallback
- automated keyboard/accessibility-tree audit plus manual screen-reader pass
- completed General and Decision Replay case reports, including limitations and
  an exact replay plus changed-model/Blueprint rerun

The Compose smoke test creates an encrypted archive and restores it into a
disposable database; keep the separate rehearsal for production storage,
credentials, timing, and recovery procedures.

The controlled-pilot sequence, support triage, disclosure templates, and
evidence matrix are in `docs/pilot-operations.md` and
`docs/pilot-release-evidence.md`.

## Public launch ownership

Before exposing a deployment outside a controlled team, the deployment owner
must publish operator-specific terms, privacy and retention language, a support
contact, and a security-reporting contact. Those details cannot be safely
hard-coded by the self-hosted runtime because the operator, processors,
jurisdiction, and retention policy vary by deployment. Confirm that configured
research and model providers are named in that notice. The workspace audit
export includes privacy-filtered SimLab studies, provenance, behavior models,
scenarios, runs, reports, and calibrations. Document the operator's manual
workspace deletion response until deletion and retention enforcement are
automated for that hosting environment.

Generic `run_create` webhooks require a bounded `Idempotency-Key`. Retrying the
same canonical payload replays the stored response and does not create another
run; reusing a key with a different payload returns `409`. Clients should retain
the key until they receive an unambiguous response.
