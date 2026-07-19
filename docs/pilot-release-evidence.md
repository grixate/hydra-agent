# Controlled-pilot release evidence

This matrix distinguishes code-complete gates from environment-dependent
qualification. A gate is `passed` only when its evidence comes from the current
candidate and the environment it claims to qualify.

Candidate deployable commit: `37891364ad43f14f53d7270ce83a05130587c621`.
The application-flow and accessibility artifacts bind to application commit
`779c610abfc0a3d302421d6984f9642807b37dbe`; later candidate commits update
release packaging, dependency security, multi-architecture build support, smoke
wiring, and evidence metadata without changing the qualified product flow.

| Gate | Current state | Evidence / required completion |
|---|---|---|
| Real no-data Build | Passed locally | General fixture completed from one question with no supplied sources; assumptions and gaps remained explicit. |
| General and Decision Replay Blueprints | Passed locally | Both current built-ins completed in `docs/pilot-cases/2026-07-18-controlled-pilot-fixture.json`. |
| Quick and Balanced modes | Passed locally | Quick completed with zero simulation calls; Balanced completed inside its hard model-call cap. |
| Hard budgets | Passed locally | Immutable route/price/cap snapshots, atomic reservations, terminal reconciliation, and failure diagnostics are covered by tests and the fixture. |
| Report validation | Passed locally | General, Decision Replay, and changed-model reports reached `ready` + `validated`. |
| State, Flow, Explain | Passed locally | All three lenses were generated for the General case; prior browser evidence covers both locales and responsive layouts. |
| Exact replay | Passed locally | Result, final-state, and decision-manifest hashes matched with zero provider calls. |
| Changed model/Blueprint repeat | Passed locally | Fresh Decision Replay rerun switched from `mock-pilot-a` to `mock-pilot-b`, changed seed, completed, and produced a validated Report. |
| Support diagnosis | Passed locally | Admin-only privacy-safe diagnostic, provider/budget/recovery/report reason counts, support code, and tests. |
| 10k performance | Passed locally | `docs/benchmarks/2026-07-18-blueprint-quick-engine-10k.json`: three 10k/20-round samples, initial p95 proxy 34.451 s, peak application memory 1.14 GB, equal result hashes, zero simulation calls. |
| 5k Balanced performance | Passed locally | `docs/benchmarks/2026-07-18-balanced-engine-5k.json`: 12 rounds in 19.19 s with 80-call and two-decisions-per-agent caps. Mock latency only. |
| Automated keyboard/semantic audit | Passed locally | 69/69 English/Russian route/viewport checks passed with zero recorded violations after target, landmark, and heading fixes. See `docs/accessibility/2026-07-18-blueprint-studio-audit.json`; rerun against the immutable deployed candidate. |
| Production image builds | Passed locally on both architectures | Application, browser-worker, and backup images built for native `linux/arm64` and emulated `linux/amd64` with non-root users and exact revision labels. The browser suite passed 11/11 per architecture, including real-Chromium rebinding controls. Trivy 0.70.0 reported zero fixable HIGH/CRITICAL findings, high/critical image misconfigurations, or embedded secrets for all six images. |
| Release smoke | Passed locally on native ARM64 and emulated AMD64 | Blank-database migrations, readiness, API auth, metrics, HSTS, compressed immutable assets, and 100 concurrent health requests passed on each architecture. AMD64 used Rosetta and Erlang's documented emulator-only `+JMsingle true` flag; the flag is not embedded in the image. |
| Compose and disposable restore smoke | Passed locally on native ARM64 and emulated AMD64 | Bounded/read-only/non-root services, isolated browser networks, provider env-file injection, encrypted backup, and disposable database restore passed on each architecture. This does not replace off-host evidence or native AMD64 target-host capacity testing. |
| Repository security and regression gate | Passed | The refreshed Hex advisory database found vulnerable locked runtime dependencies; Phoenix, Plug, Req, Mint, Postgrex, and related packages were upgraded. The final `mix precommit` reports no known dependency vulnerabilities and 710 tests with zero failures. |
| Manual screen-reader audit | Blocked on human assistive-technology session | Complete and record the VoiceOver/Safari matrix in `docs/accessibility.md`. |
| Real-provider staging | Blocked on deployment credential and route | No enabled non-mock provider or production credential exists in the current environment. Run `HydraAgent.Release.probe_provider/2` and attach the safe pass result for every enabled route/fallback. |
| Off-host restore | Blocked on independent storage and disposable restore database | Current workspace and Downloads are the same filesystem. Run `ops/backup/off-host-rehearsal` against storage that survives loss of the app host and attach its pass output. |
| Operator documentation | Passed | `docs/production.md`, `docs/pilot-operations.md`, provider staging, accessibility, backup scripts, and disclosure/case templates. |
| Public privacy/provider notice | Template and UI complete; operator values required | Set all five `HYDRA_*` disclosure variables and publish operator-reviewed templates before participants enter data. |

## Current decision

The application candidate is ready for environment qualification, not yet for a
real controlled pilot. The remaining blockers require deployment-owned external
state and cannot be truthfully substituted with mocks, same-host storage, or an
automated DOM audit. Once those rows have candidate-specific pass evidence, run
the full release suite and record the final go/no-go owner and UTC timestamp.

Exact local artifact evidence is recorded in
`docs/release/2026-07-19-production-artifact-smoke.json`.
