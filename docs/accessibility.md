# Accessibility qualification

Hydra's controlled-pilot gate combines automated semantic inspection with a
short human assistive-technology pass. Passing only a visual screenshot review
is insufficient.

## Automated keyboard and accessibility-tree audit

The Playwright audit checks every supplied route at 1,280 px, 390 px, and an
effective 320 px high-zoom layout. It fails on:

- an unexpected redirect or non-success response;
- missing language, main landmark, or single visible page heading;
- duplicate IDs, unnamed controls, broken ARIA references, or heading jumps;
- images without `alt`, unnamed canvases, or data tables without headers;
- controls below 24×24 CSS pixels, document overflow, or invisible focus;
- missing keyboard focus indicators, empty accessibility trees, or console
  errors.

It emulates reduced motion and records a SHA-256 hash of each accessibility
tree. Tree text is excluded by default because it may contain workspace data.

Run Hydra locally or against a protected staging host, then provide a dedicated
pilot account through environment variables. Keep the password out of shell
history, for example by exporting it from a password manager or hidden prompt.

```sh
cd services/browser-worker
HYDRA_A11Y_BASE_URL=https://pilot.example.test \
HYDRA_A11Y_EMAIL=audit@example.test \
HYDRA_A11Y_PASSWORD="$HYDRA_AUDIT_PASSWORD" \
HYDRA_A11Y_BROWSER_EXECUTABLE=/approved/path/to/chromium \
HYDRA_A11Y_PATHS='/simulations,/simulations/new,/blueprints,/settings/privacy,/account/security' \
HYDRA_A11Y_SCREENSHOT_DIR=/secure/release-evidence/accessibility \
npm run a11y > /secure/release-evidence/accessibility.json
```

Omit `HYDRA_A11Y_BROWSER_EXECUTABLE` when Playwright's locked Chromium is
installed. When it is set, use the reviewed browser binary from the candidate
environment; the audit never downloads one at runtime.

Add the exact Run, Analysis, State, Flow, Explain, and report paths from the two
pilot cases to `HYDRA_A11Y_PATHS`. The process exits non-zero if any checked
viewport fails. Set `HYDRA_A11Y_INCLUDE_TREE=1` only inside an approved evidence
location; the resulting JSON may contain screen text.

Use `HYDRA_A11Y_SUMMARY_ONLY=1` for a compact release artifact containing totals,
route/viewport results, and accessibility-tree hashes. Use
`HYDRA_A11Y_VERBOSE=1` temporarily when diagnosing a failed control or ARIA
reference.

## Manual keyboard pass

For English and Russian, complete the pilot journey without a pointer:

1. Use the skip link and identify the current page.
2. Create a Simulation from one question and keep Automatic defaults.
3. Open each Build stage and the preview disclosure.
4. inspect and edit model/budget controls, then start a Run;
5. move through Run progress and terminal actions;
6. switch State, Flow, and Explain, open one agent, and compare a replay;
7. generate and navigate a Report;
8. export Blueprint, Simulation Pack, and Run Pack;
9. reach privacy/data-flow and account-security information;
10. confirm every focus target is visible, ordered, named, and operable, with no
    keyboard trap or unsolicited context change.

Repeat at browser zoom 200%. At 400%, verify the 320 CSS-pixel layout reflows
without two-dimensional scrolling except inside a genuinely tabular region.

## Screen-reader pass

Use VoiceOver + Safari on macOS for the controlled pilot. Add NVDA + Firefox or
JAWS + Chrome before a broad public launch where Windows is in scope.

Verify:

- page title, language, landmark, and heading outline announce correctly;
- form purpose, required state, errors, descriptions, and disabled Run gates
  are announced before action;
- Build and Run status changes remain understandable without color or animation;
- State, Flow, and Explain each have a textual/tabular equivalent and the canvas
  is not the only source of information;
- disclosure controls announce expanded/collapsed state;
- report claims and evidence references have an intelligible reading order;
- locale changes do not mix English and Russian product copy unexpectedly;
- download actions state what will be downloaded and sensitive options remain
  deliberate.

Record browser, OS, screen-reader version, routes, locale, issues, retest result,
reviewer, and UTC date. A critical blocker, keyboard trap, unnamed primary
control, inaccessible error, or visual-only result blocks the pilot.
