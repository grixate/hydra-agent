# Controlled-pilot operations kit

This runbook is the minimum operator and support contract for a Blueprint-first
Hydra pilot. It is intentionally deployment-neutral. The deployment owner must
fill in real contacts, providers, retention, and recovery evidence before
inviting participants.

## Owners

Assign named people before launch:

| Responsibility | Must own |
|---|---|
| Release owner | reviewed image, migrations, gates, go/no-go, rollback |
| Provider owner | credentials, allowed models, staging probes, quotas, cost alerts |
| Support owner | intake, support-code diagnostics, participant communication |
| Security owner | incident triage, credential rotation, audit preservation |
| Privacy owner | notice, processors, retention, access/export/deletion response |
| Research owner | Blueprint suitability, evidence limits, case interpretation |

One person may hold several roles in a small pilot, but no responsibility may be
left implicit.

## Deployment disclosure

Set all values below. Hydra shows them under Settings → Privacy & data flow and
visibly marks the notice incomplete when any value is absent.

```text
HYDRA_OPERATOR_NAME
HYDRA_SUPPORT_EMAIL
HYDRA_SECURITY_EMAIL
HYDRA_PRIVACY_URL
HYDRA_RETENTION_SUMMARY
HYDRA_RETENTION_SUMMARY_RU # optional Russian localization
HYDRA_PRODUCT_SURFACE=blueprint_studio
```

Publish the completed privacy and provider templates in `docs/templates/`.
Provider names and model routes shown in Hydra come from enabled workspace
configuration; credential values and secret variable names are never disclosed.

## Release sequence

1. Freeze the candidate commit and record image digests.
2. Review migrations and create an encrypted off-host pre-deploy backup.
3. Run `mix precommit`, coverage, dependency audit, image builds, release smoke,
   Compose smoke, and the 10k/5k benchmark suite.
4. Restore the candidate backup into a disposable database using
   `ops/backup/off-host-rehearsal`; retain its safe evidence output.
5. Configure every pilot provider and run the live probe in
   `docs/provider-staging.md`. Qualify every enabled fallback independently.
6. Set and review the public disclosure environment.
7. Create a least-privilege pilot account and verify workspace boundaries.
8. Run the two-case fixture and then the real staging cases. The fixture command
   is:

   ```sh
   MIX_ENV=test mix run priv/pilot/pilot_cases.exs
   ```

9. Complete the automated and manual audit in `docs/accessibility.md` against
   those exact case routes.
10. Sign off the evidence matrix. Start with a bounded participant cohort and a
    support owner on call.

Do not treat the deterministic mock fixture as provider qualification or user
value evidence. Its job is to prove the application journey and contracts.

## Pilot journey

Each participant should be able to:

1. open Simulations and enter one ordinary-language question;
2. keep Automatic Blueprint, models, research, and budget defaults;
3. understand what is built, what is assumed, what data leaves the deployment,
   and what is missing;
4. inspect Population, Script, preview, hard caps, and provider routes;
5. run Quick and Balanced cases with predictable progress and terminal states;
6. understand State, Flow, Explain, Analysis, and evidence-linked Report;
7. export the Blueprint, Simulation Pack, and Run Pack;
8. replay exactly and create a fresh rerun with a changed seed or model;
9. find privacy, support, and account-security information without assistance.

Use `docs/templates/pilot-case-report.md` for General and Decision Replay. The
artifact must record strengths and limitations, not only a success screenshot.

## Support diagnosis

Ask the participant for:

- workspace and Simulation name;
- visible Run status and approximate UTC time;
- the 16-character support code;
- a Run diagnostic downloaded by a workspace admin;
- what they expected and what they observed.

The diagnostic contains public route/model metadata, hard-budget state,
reservation terminality, provider/fallback reason counts, snapshot/recovery
state, report failures, and stable next-action codes. It excludes prompts,
rationales, raw sources, provider bodies, endpoints, and credentials.

Use this triage order:

1. `blocked` severity and Run failure code;
2. active budget reservations;
3. provider and fallback reasons;
4. hard-cap rejection reasons and immutable price snapshot;
5. latest committed snapshot and recovery events;
6. report-only failures, which can be retried without rerunning the Simulation.

Never ask a participant to send an API key, database dump, raw evidence, or full
browser storage. Escalate a suspected secret exposure immediately and rotate the
affected credential outside Hydra.

## Failure response

| Failure | First action | Safe recovery |
|---|---|---|
| Provider 401/403 | Disable the affected route and notify provider owner. | Rebind/authorize the env-backed credential, probe, then rerun fresh. |
| Provider 429/outage | Preserve hard caps; do not retry blindly. | Use an independently qualified fallback or wait, then rerun. |
| Budget rejection | Inspect the immutable price and reservation state. | Create a new configuration with an intentional cap; never mutate the old Run. |
| Interrupted Run | Inspect latest committed snapshot and recovery count. | Let durable recovery resume or create a fresh rerun; preserve the failed record. |
| Report failure | Inspect validation/failure reason. | Regenerate from the same Analysis Pack; do not rerun the Simulation. |
| Suspected cross-workspace access | Stop pilot access and preserve audit evidence. | Follow the security incident process before resuming. |
| Restore failure | Stop deployment and writes. | Keep the prior image/database; diagnose the rehearsal before migration. |

## Daily pilot review

Review provider failures/fallbacks, budget rejection rates, active reservations,
failed/recovered Runs, report validation failures, rate-limit events, security
events, backup freshness, support tickets, and participant confusion. Avoid
marketing performance or accuracy claims until measurements use real provider
conditions and representative workloads.

## Go/no-go rule

The controlled pilot is a go only when every required gate has dated evidence,
an owner, and no critical open issue. Missing production credentials, a same-host
backup, mock-only cases, or an unperformed screen-reader pass are explicit
`blocked` gates—not acceptable risk notes.
