---
template_version: 1
template_name: solution
parent_problem: ./problem.md
node_kind: leaf
synthesised_from: [proposals/proposal-4.md, proposals/proposal-2.md, proposals/proposal-3.md]
selection_method: hybrid
revision: 0
---

# Solution: Failure-paired gate substrate on GitHub Rulesets + Merge Queue, with ecosystem tooling for YAML lint, diff derivation, and issue alarms

## Recommendation

Adopt proposal-4's failure-paired regression-test spine as the substrate's
shape — every required check is a pure function `(diff, repo_state,
pr_metadata) -> verdict` paired to a named v1 failure with a reproducible
SHA — and graft three ecosystem components from proposal-2 plus one from
proposal-3: (a) `rhysd/actionlint` for YAML AST traversal underneath
proposal-4's `lint-ci` meta-gate; (b) `tj-actions/changed-files`
SHA-pinned + `step-security/harden-runner` for diff derivation underneath
proposal-4's applicability resolver; (c) `peter-evans/create-issue-from-
file` for the post-merge `factory/bypass-detected` alarm; (d) **GitHub
Merge Queue** with `max_entries_to_merge=1` and
`strict_required_status_checks_policy=true` as the only path to `main`,
because it rebases the candidate onto live `origin/main` and re-verifies
the required-check set on the post-merge tree — closing the stale-green
race that proposal-4 acknowledged via `strict: true` but did not name
explicitly. Branch protection is encoded as JSON in
`.github/rulesets/main.json` (per proposal-2 — closer to GitHub's native
shape than proposal-3's Terraform-HCL and removes a runtime dependency).
Reject proposal-1's signed-verdict-ledger and proposal-3's
Sigstore/Rekor/OPA stack: their cryptographic surface is itself a new
silent-bypass channel (proposal-1 §Weaknesses concedes "a bug in
signature verification at the Bus's pre-receive hook is a silent bypass
channel"), and the operational debt (sigstore OIDC, Rekor inclusion
proofs, Rego authorship, Terraform provider) is unjustified when a
diff-derived applicability resolver already eliminates the silent-skip
surface by construction.

## Selected from

- **Chosen:** **hybrid** of `proposals/proposal-4.md` (spine) +
  `proposals/proposal-2.md` (ecosystem components a–c) +
  `proposals/proposal-3.md` (merge-queue mechanism only). Proposal-1
  rejected on cryptographic-surface grounds; proposal-3's Sigstore/OPA
  layers rejected as unnecessary infrastructure debt.
- **Why chosen:** scored against the leaf's acceptance criterion (a–f),
  the comparison is:

| # | Fit | Decomplecting depth | Migration cost | Risk | Reversibility |
|---|---|---|---|---|---|
| 1 (Verdict-Bus) | Yes | Deep | High (10 substrate PRs + key infra) | Med-High (crypto bypass channel; corrupted-registry weakness self-noted) | Hard (git-ref ledger is unconventional) |
| 2 (Ecosystem) | Yes | Substantial | Low-Med (5–8 PRs) | Med (evidence-verifier is a Claude agent — root §"where Claude is in the loop, Claude's claims must be cross-checked by mechanism" tension self-noted) | Easy |
| 3 (SLSA + OPA + MQ) | Yes | Deep | High (Rego + Sigstore + Terraform + MQ; bootstrap trust hole) | High (5 infra deps; toolchain-down day blocks all merges) | Hard |
| 4 (Adversarial replay) | Yes | Deep | Low (4 mix tasks + 2 JSON registries; ~5 PRs) | Low (each mechanism paired to a reproducible v1 SHA) | Easy |

  Proposal-4 dominates on fit, decomplecting depth, migration cost, risk,
  and reversibility simultaneously. Its only structural gap — the
  stale-green race when `main` advances between gate-green and merge — is
  filled by proposal-3's merge-queue mechanism (the single layer of
  proposal-3 that pays for itself; the rest is operational debt
  proposal-4 already accomplishes without). Proposal-2 contributes
  battle-tested tooling for the *implementations* of proposal-4's
  abstract checks (actionlint replaces hand-rolled YAML parsing;
  tj-actions/changed-files replaces hand-rolled `git diff --name-only`
  wrappers; peter-evans/create-issue-from-file replaces hand-rolled
  `gh issue create` glue). Per selector heuristic "composition over
  aggregation," each grafted component has a typed contract with the
  proposal-4 spine and is independently replaceable. The
  evidence-verifier-as-Claude-agent surface from proposal-2 §D is
  explicitly **NOT** grafted — its bespoke replacement
  (`mix tau.gate.evidence_binder`, proposal-4 artefact 3) is the
  load-bearing path, satisfying the root constraint that Claude's claims
  not gate merges.

## What changes

### Artefacts created (file-level)

The substrate ships **fifteen** concrete artefacts. Each is named below
with its absolute repo path, its purpose, and the failure class
(`F#` = root §Hypothesis numbering) and acceptance clause (`§a–f`) it
satisfies.

**Branch-protection / merge-queue (ruleset-as-code).**

1. `.github/rulesets/main.json` — encoded GitHub Repository Ruleset for
   `main`: `enforcement: active`; `bypass_actors: []` (no admin
   override); `required_linear_history: true`; `strict_required_status_
   checks_policy: true`; `required_status_checks` enumerated below in
   step §a; merge queue `max_entries_to_merge: 1`,
   `max_entries_to_build: 3`. Authoritative; the live ruleset is diffed
   against this file on every PR. Closes F#7, §c.

2. `.github/required-checks.json` — single source of truth for the
   required-check name set. The ruleset's `required_status_checks`
   field is generated from this file; the `lint-ci` meta-gate reads it
   to know which jobs `continue-on-error: true` is forbidden on; the
   ruleset-drift gate reads it for the comparison. One file, three
   consumers — eliminates the v1 drift between ruleset and CI YAML.

3. `.github/workflows/ruleset-apply.yml` — push-to-`main` workflow that
   applies `.github/rulesets/main.json` via direct `gh api PUT
   repos/:owner/:repo/rulesets/:id` (one `gh` call; no third-party
   action needed for this trivial wrap). Idempotent.

4. `.github/workflows/ruleset-drift.yml` — required check; runs on
   every PR and on daily cron. `gh api repos/:owner/:repo/rulesets` →
   `jq -S` normalise → byte-diff against `.github/rulesets/main.json`.
   Drift fails the PR AND invokes `peter-evans/create-issue-from-file`
   to open a `factory/ruleset-drift` P0 issue. Closes F#7, §c.

**Meta-gate over CI configuration.**

5. `.github/workflows/lint-ci.yml` — required check (`lint-ci`). Two
   stages:
   - **Stage 1: actionlint.** `rhysd/actionlint@v1.7.5` (SHA-pinned)
     parses every `.github/workflows/*.yml` for general YAML
     correctness — replaces hand-rolled YAML parsing per proposal-2.
   - **Stage 2: forbidden-pattern check** via
     `mix tau.gate.lint_ci`. Reads `.github/required-checks.json` and
     each workflow YAML AST; fails on any of:
       - `|| true`, `|| :`, `; true`, `; :` at end-of-line in a `run:`
         block belonging to a required job;
       - `continue-on-error: true` on a required job;
       - any `if:` expression containing the literal substring
         `github.event.pull_request.body`;
       - any `paths:` / `paths-ignore:` filter on a required job
         (path-filters are silent-skip channels per proposal-1);
       - any `actions/checkout` with `persist-credentials: true` on a
         required job.
   Closes F#5, §b.

**Diff-derived applicability resolver.**

6. `lib/mix/tasks/tau.gate.applicability.ex` — pure Elixir function
   `Tau.Factory.Applicability.compute/3` taking `(diff_paths,
   repo_root, pr_metadata)` and returning a map from `gate_id` to the
   set of files / AST nodes the gate is responsible for. Reads
   `tj-actions/changed-files`-SHA-pinned JSON output passed via stdin;
   never reads PR-body text. Used by Gate 5.1 / 5.3 (sibling
   `pre-merge-code-gates` leaf consumes the same module).

7. `.github/actions/changed-files/action.yml` — composite wrapper
   pinning `tj-actions/changed-files@<exact-commit-sha>` plus
   `step-security/harden-runner@<sha>` with audited egress allow-list
   (the CVE-2025-30066 mitigation per proposal-2). Every required
   workflow uses this wrapper rather than referencing `tj-actions`
   directly — a single update site for the SHA pin. Closes F#5, §a.

**Verdict-shape enforcement.**

8. `lib/tau/factory/verdict.ex` — `Tau.Factory.Verdict` struct +
   exhaustive sum type:

```elixir
defmodule Tau.Factory.Verdict do
  @enforce_keys [:gate_id, :head_sha, :applicable_inputs, :status,
                 :reason, :emitted_at]
  defstruct [:gate_id, :head_sha, :applicable_inputs, :status,
             :reason, :emitted_at, :findings, :tool_version]
  @type status :: :pass | :fail | :checked_no_applicable | :infra_failure
end
```

   There is **no `:skipped` constructor** — exhaustiveness asserted by a
   property test (`test/tau/factory/verdict_test.exs`,
   `@tag :property`) that round-trips arbitrary verdicts and by a
   Dialyzer spec the `mix dialyzer` job already runs. Every required
   mix-gate task emits a verdict on stdout (JSON-encoded per
   `priv/schemas/verdict.schema.json`). Closes F#5, §a (silent-skip is
   syntactically unrepresentable).

9. `priv/schemas/verdict.schema.json` — JSON Schema for the verdict
   payload; consumed by the operability-leaf dashboard and by CI
   assertions that every required job's stdout parses as a valid
   verdict.

**Evidence-binder gate.**

10. `lib/mix/tasks/tau.gate.evidence_binder.ex` — required check.
    Scans the PR body (fetched via `gh pr view --json body`) for token
    patterns matching `mix test`, `mix compile`, `Finished in`,
    `\d+ tests?, \d+ failures?`, `assert .* passed`, `iex>`, or any
    backtick-fenced block starting with `$ mix `. For every match,
    requires a sibling `https://github.com/<owner>/<repo>/actions/runs/
    <id>` URL whose `head_sha` (fetched via `gh api`) equals
    `pr.head.sha`. Pure deterministic Elixir; no LLM in the loop —
    this is the explicit replacement for proposal-2's
    `evidence-verifier` Claude agent. Closes F#7, §d.

**Post-merge alarm.**

11. `.github/workflows/post-merge-audit.yml` — runs on `push: main`.
    For every new merge commit, calls
    `gh api repos/:owner/:repo/commits/:sha/check-runs --jq` to
    enumerate required-check conclusions; if any required check is not
    `success` for the head SHA, opens a `factory/bypass-detected` P0
    issue via `peter-evans/create-issue-from-file@<sha>` with the
    merge SHA, the merger identity, and the failing check names.
    Catches the residual case where Rulesets fail open (GitHub outage,
    ruleset misconfiguration). Closes F#7 (residual), §c.

**Role-separation and scope-coherence gates.**

12. `lib/mix/tasks/tau.gate.commit_roles.ex` + `infra/commit-roles.json`
    — required check. For each commit on `pr.head` (via
    `gh pr view --json commits`), enforces the rules encoded in
    `infra/commit-roles.json` (rule set: `tau-reviewer` MAY NOT author
    diffs under `lib/`, `test/`, `web/lib/`; `Co-Authored-By: Claude`
    on diffs touching `SPEC-*.md` Appendix-B files requires a sibling
    `Reviewed-By:` trailer with a distinct identity). Per proposal-4
    artefact 6. Closes a v1 role-collapse pattern; supports §a by
    ensuring the role authoring a verdict is distinct from the role
    consuming it.

13. `lib/mix/tasks/tau.gate.scope_coherence.ex` + `infra/scope-
    packages.json` — required check. Parses the fenced `scope` JSON
    block in the PR body; computes `actual_roots = unique_top_level_
    dirs(diff.touched_paths, depth=3)`; fails on `actual_roots ⊄
    declared touched_roots` or `touched_roots` spanning more than one
    declared package. Per proposal-4 artefact 7. The single PR-body
    field the substrate reads is the `scope` JSON block — and the
    `scope-coherence` gate's role is to *contradict* the PR body
    against the diff, not to *trust* it.

**Regression-test harness (proposal-4 spine).**

14. `test/factory/v1_failure_regression_test.exs` — one regression
    test per reproduced v1 failure (#411, #412, #413, #414, role-
    collapse, atomicity). Each test:
    - reconstructs the bad PR's diff + body + commit metadata from
      fixtures under `test/factory/fixtures/pr-<n>/`;
    - invokes the substrate's verdict pipeline as a pure function;
    - asserts the substrate returns `:fail` with the named class.
    Tagged `@tag :gating` so it appears in Gate 5.1's tracked set per
    SPEC-USER-TURN conventions. Adding a sixth v1 failure means
    adding a sixth fixture directory + a sixth test — the regression
    set grows monotonically.

15. `docs/adr/ADR-NNN-factory-v2-gate-substrate.md` — ADR recording
    (a) the rejection of proposal-1's signed-verdict-ledger and
    proposal-3's full SLSA/OPA stack, with reasoning; (b) the
    bootstrap admin push that lands artefacts 1–4 (a one-time
    unattested seed event documented per `tau-adr` conventions);
    (c) the rule that subsequent edits to `.github/rulesets/main.json`,
    `.github/required-checks.json`, `infra/commit-roles.json`,
    `infra/scope-packages.json` require a `Reviewed-By:` trailer from
    a human identity (closes proposal-1's "corrupted registry"
    weakness without multi-sig infrastructure).

### Modifications to existing files

- `.github/workflows/ci.yml` — delete lines 88-100 (Gate 5.1
  silent-skip), line 115 (`|| true`), lines 213-223 (Gate 5.3
  silent-skip). Replace with always-on gate invocations that read
  applicability from `mix tau.gate.applicability`. Each required job
  exits with the verdict's deterministic exit code (`:pass | :checked_
  no_applicable -> 0`; `:fail | :infra_failure -> non-zero`).
- `.claude/rules/factory-loop.md` — remove the `Gating-test paths`
  PR-body section requirement; replace with a single-sentence pointer
  to the diff-derived resolver. Add a one-paragraph description of the
  `scope` JSON block contract. Remove any guidance to cite local
  `mix test` output as evidence in PR bodies.
- `lib/mix/gate/{ac_linkage,masking,mutation}.ex` (the three v1 mix
  tasks) — reshape to emit `Tau.Factory.Verdict` JSON on stdout;
  remove all internal PR-body parsing; replace any internal
  `applicable_inputs` derivation with a call into
  `Tau.Factory.Applicability.compute/3`.

### Silent-skip impossibility — concrete implementation

Per acceptance §a — restated at the implementation level so a reviewer
can falsify each clause against the artefacts above:

1. **No required gate may silent-skip.** The `Tau.Factory.Verdict`
   sum type (artefact 8) has no `:skipped` constructor; a Dialyzer
   spec asserts exhaustiveness; the property test
   `test/tau/factory/verdict_test.exs` round-trips arbitrary verdicts
   and would fail to compile if a fifth constructor were added without
   updating the type. The CI step that consumes a gate's stdout
   parses against `priv/schemas/verdict.schema.json` (artefact 9) and
   fails the job on schema-mismatch — a gate that prints free text
   instead of a verdict is treated as `:infra_failure`.

2. **The substrate cannot be configured to silent-skip.** Removing a
   required check from `.github/required-checks.json` (artefact 2) is
   a diff visible to `scope-coherence` (artefact 13), which refuses
   it unless the PR's `scope.package == "factory.required-checks"` —
   a privileged scope whose entries in `infra/scope-packages.json`
   require a `Reviewed-By:` trailer from a human identity (ADR-NNN
   rule per artefact 15). The ruleset-drift gate (artefact 4) catches
   any divergence between live ruleset and the file.

3. **The substrate cannot disable itself via `|| true`,
   `continue-on-error: true`, or PR-body-keyed `if:`.** The `lint-ci`
   meta-gate (artefact 5) is itself in `.github/required-checks.json`
   (artefact 2); its forbidden-pattern check forbids these four
   anti-patterns on any required job. Disabling `lint-ci` is case 2
   above. Path-filters (`paths:` / `paths-ignore:`) on required jobs
   are also forbidden — closing proposal-1's "path-filtered out" sub-
   failure as well.

4. **The substrate cannot be bypassed by an admin merge.**
   `bypass_actors: []` in `.github/rulesets/main.json` (artefact 1)
   removes the admin-override path. Editing this field is a diff
   ruleset-drift (artefact 4) catches; if a human nonetheless edits
   the live ruleset on github.com, the post-merge audit workflow
   (artefact 11) opens a `factory/bypass-detected` P0 issue on the
   next push to `main`.

5. **The substrate cannot merge against red CI.** GitHub Merge Queue
   with `strict_required_status_checks_policy: true` (artefact 1)
   rebases the merge candidate onto current `origin/main` and
   re-evaluates every required check on the post-merge tree. A green
   pre-merge gate verdict that would be red after rebase fails the
   queue entry — closing proposal-4's implicit gap (proposal-4 relied
   on `strict: true` alone, which forces up-to-date but does not
   re-verify the post-merge tree).

6. **The substrate cannot infrastructurally silent-pass.** A required
   job that crashes (toolchain missing, network timeout, runner OOM)
   reports `conclusion: failure` to GitHub — required-checks gating
   fails the PR. A job that emits invalid stdout per the verdict
   schema is treated as `:infra_failure` (`exit 1`) by the
   schema-validation wrapper, not silently passed.

### Reuse-vs-build accounting (per root §Acceptance D)

| Capability | Decision | Component | Bespoke surface |
|---|---|---|---|
| Branch-protection encoding | **Adopt** | GitHub Repository Rulesets API | `.github/rulesets/main.json` (config only) |
| Ruleset apply / drift | **Build (thin)** | `gh api PUT/GET` + `jq -S` | ~30 lines YAML each (artefacts 3, 4); no third-party action needed |
| Workflow YAML lint (general) | **Adopt** | `rhysd/actionlint` SHA-pinned | none |
| Workflow forbidden-pattern check | **Build** | `mix tau.gate.lint_ci` over YAML AST | ~150 LoC Elixir (artefact 5); no ecosystem equivalent for the four custom patterns |
| Diff-derived applicability | **Adopt + thin glue** | `tj-actions/changed-files@<sha>` + `step-security/harden-runner@<sha>` wrapped in `.github/actions/changed-files/` | ~20 lines YAML (artefact 7) |
| Applicability computation | **Build** | `Tau.Factory.Applicability` | ~200 LoC Elixir (artefact 6) — pure function, project-specific glob rules |
| Verdict shape | **Build** | `Tau.Factory.Verdict` sum type | ~80 LoC Elixir + JSON Schema (artefacts 8, 9) |
| Evidence binder | **Build** | `mix tau.gate.evidence_binder` | ~150 LoC Elixir (artefact 10) — deterministic, no LLM (explicitly NOT proposal-2's claude-code-action path) |
| Post-merge alarm | **Adopt + thin glue** | `peter-evans/create-issue-from-file@<sha>` + `gh api` | ~40 lines YAML (artefact 11) |
| Merge queue | **Adopt** | GitHub Merge Queue (native) | configured in artefact 1 |
| Commit-role check | **Build** | `mix tau.gate.commit_roles` + `infra/commit-roles.json` | ~120 LoC Elixir (artefact 12) — no ecosystem equivalent |
| Scope-coherence | **Build** | `mix tau.gate.scope_coherence` + `infra/scope-packages.json` | ~150 LoC Elixir (artefact 13) — no ecosystem equivalent |
| Regression harness | **Build** | ExUnit fixtures | one fixture dir + one test per v1 failure (artefact 14) |

Bespoke totals: ~900 LoC Elixir across six mix tasks + ~120 lines of YAML
glue + four JSON registries + ADR-NNN. Every bespoke component has a
one-line "no ecosystem equivalent" justification embedded above. Six
ecosystem components adopted (GitHub Rulesets, GitHub Merge Queue,
actionlint, tj-actions/changed-files, harden-runner, create-issue-from-
file). Per root §Acceptance D, the build justifications are explicit and
the adopt-vs-build axis biases toward adopt where coverage exists.

### Integration with sibling leaves

- **`pre-merge-code-gates` sibling** owns the *content* of each AST /
  contract / capability-flag check; **this leaf** owns the *substrate*
  they emit verdicts into. Concretely: every mix gate that sibling
  defines emits a `Tau.Factory.Verdict` per artefact 8, gets registered
  in `.github/required-checks.json` per artefact 2, and its workflow
  YAML is constrained by artefact 5. The shared interface is the
  Verdict struct and the JSON Schema.

- **`intent-capture-and-ac-binding` sibling** consumes
  `Tau.Factory.Applicability` (artefact 6) for its AC↔test binding;
  the diff-derived gating-test set defined here replaces v1's
  `Gating-test paths` PR-body section that sibling formerly read.

- **`operability-and-hygiene-enforcement` sibling** consumes the
  verdict JSON stream (artefacts 8, 9) and the `factory/bypass-
  detected` issue label for the dashboard; this leaf produces the
  verdicts, that leaf displays them. The post-merge audit workflow
  (artefact 11) is the upstream of that leaf's bypass-detection
  surface.

- **`knowledge-memory-and-audit-ingestion` sibling**: audit registry
  entries become applicability inputs to specific gates via
  `Tau.Factory.Applicability.compute/3`'s `pr_metadata` argument (a
  module flagged by an audit becomes an applicable input to the
  corresponding gate).

- **`post-merge-cross-artifact-coherence` sibling**: ruleset-drift
  (artefact 4) and post-merge audit (artefact 11) are pre-merge
  surfaces; that sibling owns the cadenced `main`-side re-audits that
  catch cross-PR drift the per-PR substrate cannot see.

## What does not change

- `Tau.Factory.Gate` module (`lib/tau/factory/gate.ex`) — the three
  pure verdict-producing functions remain; they get a new return shape
  (the `Verdict` struct) and a new applicability input, but the
  predicate logic is preserved. No functionality regression on
  existing gates.
- The `/pr` skill and the critic/reviewer agent personas continue to
  exist as quality checks; they MAY NOT be load-bearing for any of the
  ten root §Hypothesis failure classes (per root §Acceptance B).
- The factory-loop's serialized-merge invariant
  (`max_entries_to_merge: 1` in artefact 1) preserves the
  `factory-loop.md` cycle-step-8 guarantee that merges are sequential.
- Pre-existing properties tests under `test/property/` and unit tests
  under `test/tau/` continue to pass; the substrate is layered above
  them.
- The `.tool-versions` Erlang/Elixir pins (1.18.1 / OTP 27.2);
  no new BEAM-level runtime dependency.
- `mix dialyzer` and `mix credo --strict` continue as `lint`-job
  components.

## §Build-order

Each step is one PR per the factory loop. Each step's exit-criterion is
a check the next step can run against. Step N may not begin until step
N-1's exit-criterion is itself a green CI verdict on `main`. Total
sequence: **12 PRs over an estimated 8 weeks**, value lands
incrementally — the first usable trust gain is at step 4 (week 2).

The substrate's bootstrap problem (proposal-3 §Weaknesses) is handled
by sequencing: artefacts 1–4 land before the meta-gates that would gate
their own creation. ADR-NNN (artefact 15) documents this one-time
unattested admin push window, per `tau-adr` conventions.

### Week 1 — Foundation (no behaviour change yet)

**PR 1: Verdict shape + JSON Schema** (artefacts 8, 9).
- Land `Tau.Factory.Verdict` struct, sum type, Dialyzer spec.
- Land `priv/schemas/verdict.schema.json`.
- Land `test/tau/factory/verdict_test.exs` property test.
- **Dependencies:** none.
- **Exit:** `mix test test/tau/factory/verdict_test.exs` green;
  `mix dialyzer` confirms exhaustive sum type.

**PR 2: Applicability resolver + diff-derived input wrapper**
(artefacts 6, 7).
- Land `Tau.Factory.Applicability.compute/3` with property tests.
- Land `.github/actions/changed-files/action.yml` SHA-pinning
  `tj-actions/changed-files` + `step-security/harden-runner`.
- **Dependencies:** PR 1 (uses Verdict shape in tests).
- **Exit:** property test asserts determinism on identical
  `(diff, repo_root, pr_metadata)` input across 100 generations;
  composite action runnable locally via `act`.

### Week 2 — Branch protection encoded (closes admin-override path)

**PR 3: Ruleset-as-code + ruleset-drift gate + ruleset-apply
workflow** (artefacts 1, 3, 4).
- Land `.github/rulesets/main.json` reconciled with current live
  ruleset.
- Land `.github/workflows/ruleset-apply.yml`.
- Land `.github/workflows/ruleset-drift.yml` (initially *not* required
  — added to required set in PR 5 after one PR-cycle of shadow mode).
- **Dependencies:** PR 1 (drift workflow emits a Verdict).
- **Exit:** `gh api repos/:owner/:repo/rulesets` round-trips byte-
  equal to file (proposal-2's noted concern resolved or a normalisation
  step added); shadow-mode drift gate runs green on the next PR.
- **First trust gain:** `bypass_actors: []` is now live; admin merge of
  red PRs is structurally blocked on day 1.

**PR 4: Required-checks single-source + lint-ci meta-gate (audit-mode)**
(artefacts 2, 5).
- Land `.github/required-checks.json` mirroring the current required
  set.
- Land `.github/workflows/lint-ci.yml` running `rhysd/actionlint` +
  `mix tau.gate.lint_ci` in audit-mode (logs findings, does not fail).
- **Dependencies:** PR 1, PR 3.
- **Exit:** audit-mode flags the existing `|| true` at `ci.yml:115`
  and the silent-skip blocks at `:88-100` and `:213-223`.

### Week 3 — Meta-gate goes blocking; verdict shape adopted

**PR 5: Promote ruleset-drift and lint-ci to required; fix audit
findings.**
- Add `ruleset-drift` and `lint-ci` to
  `.github/required-checks.json`; regenerate ruleset.
- Delete `ci.yml:88-100`, `:115`, `:213-223`. Replace with always-on
  gate invocations using `Tau.Factory.Applicability`.
- **Dependencies:** PRs 1–4.
- **Exit:** `lint-ci` would have blocked the v1 PR #411 fixture
  (replay test in PR 12).
- **Second trust gain:** `|| true` and silent-skip patterns are
  structurally rejected.

### Week 4 — Existing v1 gates migrate to Verdict shape

**PR 6: Reshape `mix tau.gate.{ac_linkage,masking,mutation}` to emit
Verdicts.**
- Each task emits `Tau.Factory.Verdict` JSON on stdout.
- Each task's `applicable_inputs` derives from
  `Tau.Factory.Applicability.compute/3`.
- CI wrapper validates stdout against `priv/schemas/verdict.schema.
  json`.
- **Dependencies:** PRs 1, 2, 5.
- **Exit:** all three existing gates pass with new shape on the
  current `main`; one synthetic PR with no gating tests demonstrates
  `:checked_no_applicable` flowing through correctly.

### Week 5 — Evidence-binder + post-merge alarm

**PR 7: Evidence-binder gate** (artefact 10).
- Land `mix tau.gate.evidence_binder`.
- Add `evidence-binder` to required-checks.
- **Dependencies:** PRs 1, 5.
- **Exit:** synthetic PR pasting `mix test` output without a CI-run
  URL is blocked; synthetic PR with correct SHA-pinned URL passes.

**PR 8: Post-merge audit + bypass-detected alarm** (artefact 11).
- Land `.github/workflows/post-merge-audit.yml` using
  `peter-evans/create-issue-from-file`.
- **Dependencies:** PR 5 (consumes required-checks list).
- **Exit:** simulated admin-override merge in a fork opens a
  `factory/bypass-detected` issue.

### Week 6 — Role + scope-coherence gates

**PR 9: Commit-roles gate** (artefact 12).
- Land `mix tau.gate.commit_roles` + `infra/commit-roles.json`.
- Add `commit-roles` to required-checks.
- **Dependencies:** PR 5.
- **Exit:** synthetic PR with `tau-reviewer` authoring `lib/**`
  changes is blocked; PR with the same diff authored by
  `tau-implementer` passes.

**PR 10: Scope-coherence gate** (artefact 13).
- Land `mix tau.gate.scope_coherence` + `infra/scope-packages.json`
  populated with current ~12 packages.
- Add `scope-coherence` to required-checks.
- **Dependencies:** PR 5.
- **Exit:** PR #412 fixture (three-package PR with single-package
  declaration) is blocked; well-scoped synthetic PR passes.

### Week 7 — Merge queue (closes stale-green race)

**PR 11: Enable GitHub Merge Queue.**
- Update `.github/rulesets/main.json` to add `merge_queue` block with
  `max_entries_to_merge: 1`, `max_entries_to_build: 3`,
  `merge_method: MERGE`, `strict_required_status_checks_policy: true`.
- Update `factory-loop.md` cycle step 8 to enqueue rather than
  direct-merge.
- **Dependencies:** PRs 1–10 (queue runs the now-complete required set
  against post-merge tree).
- **Exit:** PR that was gate-green pre-rebase but fails post-rebase
  (e.g. test broken by an intervening `main` advance) is rejected by
  the queue.
- **Third trust gain:** stale-green race is closed; the v1 collapse
  pattern of merging against advanced-`main` is structurally
  impossible.

### Week 8 — Regression harness + ADR + cleanup

**PR 12: V1 failure regression tests + ADR** (artefacts 14, 15).
- Land `test/factory/v1_failure_regression_test.exs` with fixtures
  reconstructing #411, #412, #413, #414, role-collapse, atomicity.
- Land `docs/adr/ADR-NNN-factory-v2-gate-substrate.md`.
- Tag the regression tests `@tag :gating` so Gate 5.1 tracks them.
- **Dependencies:** all prior PRs (the substrate is now complete; the
  tests prove it rejects every reproduced v1 failure).
- **Exit:** each regression test green; ADR merged per `tau-adr`
  conventions.

### Build-order monotonicity invariant

At every step, the failure classes the new mechanism is supposed to
block are tested by a synthetic-PR probe or the regression-test
harness, landed in the same PR as the mechanism. No mechanism lands
without its falsification probe. The PR-12 regression suite is the
final, comprehensive falsification.

### Sequencing dependencies (visual)

```
Week 1:  PR1 ───────────────────┐
         PR2 ───┐               │
                │               │
Week 2:  PR3 ───┤               │
         PR4 ───┤               │
                │               │
Week 3:  PR5 ───┴───┐           │
                    │           │
Week 4:  PR6 ───────┤           │
                    │           │
Week 5:  PR7 ───────┤           │
         PR8 ───────┤           │
                    │           │
Week 6:  PR9 ───────┤           │
         PR10 ──────┤           │
                    │           │
Week 7:  PR11 ──────┤           │
                    │           │
Week 8:  PR12 ──────┴───────────┘
```

PRs in the same week may proceed in parallel iff the factory-loop's
parallel-execution conflict check clears (per `factory-loop.md`
§Parallel execution). PR 5 is the serialization point — every gate
that follows it relies on the lint-ci / ruleset-drift required-check
guarantees.

## Open questions

- **GitHub Rulesets API round-trip fidelity.** Proposal-2 flagged this;
  PR 3 must include a half-day spike that confirms `gh api repos/:owner/
  :repo/rulesets` round-trips byte-equal to `.github/rulesets/main.json`.
  If lossy, PR 3 adds a `jq`-based semantic normaliser to the drift
  check (still mechanical, just one more transformation step).

- **GitHub Merge Queue's behaviour when the post-rebase tree fails a
  required check that was green pre-rebase.** Documentation says the
  queue rejects the entry and notifies the author; needs confirmation
  that the failure is logged (so the operability dashboard can surface
  it) rather than silently dropped.

- **Hotfix path when an infra failure (e.g. flaky setup-beam Action)
  affects every PR.** With `bypass_actors: []` and
  `enforce_admins: true`, there is no admin override. The mitigation is
  a documented "infra-hotfix" workflow: revert the broken Action SHA
  via a PR that does not require the affected Action (path-restricted
  to `.github/`). This is an inconvenience by design; the alternative —
  leaving an admin-override path — re-introduces the v1 collapse mode.
  May need user input on whether this is acceptable; default is "yes,
  per root §Hypothesis #7".

- **`tj-actions/changed-files` supply-chain risk.** SHA-pinning +
  `step-security/harden-runner` mitigates CVE-2025-30066-class
  incidents but does not eliminate them. An Anthropic-vendored
  alternative (if it materialises by 2026-Q3) would drop the
  mitigation requirement; until then, the wrapper at artefact 7 is
  the single update site.

- **Substrate self-modification policy.** ADR-NNN (artefact 15)
  asserts that edits to `.github/rulesets/main.json`,
  `.github/required-checks.json`, `infra/commit-roles.json`,
  `infra/scope-packages.json` require a `Reviewed-By:` trailer from a
  human identity. This is enforced by the `commit-roles` gate via an
  entry in `infra/commit-roles.json`. The bootstrapping case — the PR
  that first lands `infra/commit-roles.json` — is the one-time admin
  push documented in the ADR; subsequent edits are gated. Confirm with
  user that "human Reviewed-By" is a satisfactory closure of
  proposal-1's "corrupted registry" weakness without escalating to
  multi-sig.

- **Coordination with the `pre-merge-code-gates` sibling on the
  Verdict struct interface.** The struct is the shared contract; if
  that sibling needs additional fields (e.g. `severity`,
  `category`), the struct must accommodate them additively
  (`@enforce_keys` minimal; optional fields free). Coordinate
  before PR 1 lands.

- **Operability-leaf consumer naming.** The dashboard reads
  `factory/bypass-detected`, `factory/ruleset-drift` issue labels and
  the verdict JSON stream. Coordinate label naming before PR 8 to
  avoid renaming churn.

## Linked sub-problems / proposals

- `proposals/proposal-1.md` — *Verdict-Bus signed ledger*. Rejected:
  cryptographic surface itself a silent-bypass channel
  (self-documented weakness); `refs/factory/verdicts` ledger
  unconventional; corrupted-registry weakness unresolved without
  multi-sig. Some terminology adopted (`Verdict` struct name,
  applicability oracle pattern).
- `proposals/proposal-2.md` — *Ecosystem reuse*. Hybrid contributor:
  `rhysd/actionlint`, `tj-actions/changed-files`+`harden-runner`,
  `peter-evans/create-issue-from-file`, ruleset-as-JSON shape (vs
  proposal-3's HCL), and the structural argument that GitHub already
  ships the decomplecting primitives. Explicitly rejected:
  `claude-code-action`-driven evidence-verifier (LLM in the
  load-bearing path violates root §"Claude's claims must be
  cross-checked by mechanism").
- `proposals/proposal-3.md` — *SLSA + OPA + Merge Queue*. Single
  contribution: **GitHub Merge Queue** as the only path to `main`,
  closing the stale-green race. Rejected: SLSA attestations,
  Sigstore/Rekor, OPA/Rego, Terraform-managed branch protection —
  operational debt unjustified once diff-derived applicability
  eliminates silent-skip by construction.
- `proposals/proposal-4.md` — *Adversarial v1-replay*. Spine of the
  solution: failure-paired regression-test substrate, diff-derived
  applicability resolver, commit-roles gate, scope-coherence gate,
  lint-ci meta-gate, evidence-binder gate, required-checks JSON
  single-source. Every catching mechanism inherits proposal-4's
  property of being paired to a reproducible v1 failure SHA.

## Revision history

- (revision 0 — initial; 2026-05-23)
