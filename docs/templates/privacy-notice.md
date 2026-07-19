# Hydra deployment privacy notice — operator template

> Replace every bracketed field. Obtain legal/privacy review appropriate to the
> deployment and jurisdiction. Do not publish this template unchanged.

- **Operator:** [legal/operator name]
- **Effective date:** [YYYY-MM-DD]
- **Privacy contact:** [email and URL]
- **Support contact:** [email]
- **Security reports:** [email or reporting URL]

## Purpose

[Operator] uses this self-hosted Hydra deployment to create and inspect
synthetic agent simulations for [bounded pilot purpose]. Results are modeled
scenarios, not observations, forecasts, or automated decisions about people.

## Data we process

Describe the actual deployment:

- account and workspace membership data: [fields];
- questions, notes, uploaded files, and submitted URLs: [scope];
- retrieved source metadata, excerpts, claims, assumptions, and gaps: [scope];
- synthetic populations, scripts, runs, snapshots, decisions, analyses, reports,
  exports, budgets, and usage records: [scope];
- security, audit, rate-limit, backup, and support records: [scope].

Do not upload [prohibited categories, secrets, regulated personal data, or other
operator restrictions]. State whether participant content is expected to contain
personal data and what minimization/redaction process applies.

## Where data goes

Name every enabled processor and route using the provider disclosure. Explain:

- which Build, simulation, report, search, browser, MCP, or local-model stages
  may receive data;
- region and account/project controls;
- whether provider training is disabled and under which agreement;
- that Quick simulation execution makes zero simulation model calls, while
  Build and Report may still use configured services;
- that raw sources are excluded from portable exports by default;
- that Hydra stores environment-variable references, not raw provider secrets.

## Human control and limitations

Users can inspect Context, assumptions, gaps, Population, Script, hard budgets,
model routes, State, Flow, Explain, evidence references, and Run lineage. Hydra
does not establish causality, truth, individual behavior, legal conclusions, or
future outcomes. Explain how [Operator] reviews results before use.

## Retention, deletion, and backups

State exact periods and behavior:

- active workspace content: [period/rule];
- audit and security records: [period/rule];
- encrypted backups: [period/rule and off-host location category];
- provider-side retention: [provider-specific periods];
- account/workspace export and deletion request process: [steps, SLA, contact];
- backup expiry after a deletion: [period].

Do not promise immediate erasure from immutable audit or backups unless the
deployment actually enforces it.

## Access and security

Describe least-privilege workspace roles, TLS, secret handling, audit export,
encrypted backups, restore rehearsals, incident reporting, and any identity
provider. State the limits of security guarantees.

## Rights and questions

Describe rights and complaint routes that apply to [jurisdiction/data subjects],
how identity is verified, and the privacy contact above.
