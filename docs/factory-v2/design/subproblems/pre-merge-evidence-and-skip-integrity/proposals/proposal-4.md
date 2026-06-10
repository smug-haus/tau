---
template_version: 1
template_name: proposal
proposal_id: 4
parent_problem: ../problem.md
---

# Proposal 4: Adversarial v1-replay substrate — each catching mechanism is a regression test against an exact reproduced failure

## Approach

Rather than designing a gate substrate abstractly, this proposal constructs
the substrate as the **fixed set of mechanisms required to deterministically
reject the five concrete v1 failures already on disk** (#411–#414 and the
two role/atomicity violations behind them). Each mechanism is paired to a
named v1 failure with an exact diff/SHA citation, has a single deterministic
check, and is wired so the check's *applicability* is computed from the
diff/repo/PR-metadata triple — never from a PR-body declaration field.
Concretely, the v2 substrate ships seven artefacts: (1) a "required CI
contexts" file (`.github/required-checks.json`) consumed by both branch
protection *and* a meta-gate; (2) a workflow self-check job (`lint-ci`) that
parses every `.github/workflows/*.yml` AST and fails on `|| true`,
`continue-on-error: true` on a required check, and any `if:` predicate
referencing `github.event.pull_request.body`; (3) a head-SHA evidence binder
that resolves every PR-body "evidence" claim to an `actions/runs/<id>` whose
`head_sha == pr.head.sha`; (4) a diff-derived applicability resolver so
Gate 5.1/5.3 read gating-test paths from the diff (any `test/**/*_test.exs`
file touched in the PR), not from a PR-body section that can be empty; (5)
a branch-protection-as-code artefact (`infra/branch-protection.json`) plus
a drift-detector job; (6) a commit-trailer attestation check that rejects
the PR when commits authored by `tau-reviewer` exist on the head ref (role
separation); (7) a scope-coherence gate that asserts the diff's "changed
top-level package set" (e.g. `{lib/mix/gate, lib/tau/tui, docs/spec}`) is
declared in the PR body's `## Scope` table and consists of a single
coherent unit per the declared scope-coherence rules. None of these can be
disabled by a PR omitting a field, by a `|| true`, or by an admin merge —
the meta-gate verifies the substrate's own configuration on every PR.

## Rationale

The v1 substrate failed because each gate decided *whether to run* by
reading the PR body. The reverse complecting hypothesis from the leaf
problem ("whether a gate runs" complected with "whether the PR opted in")
is most cleanly broken by **forcing every gate's input universe to be a
pure function of `(diff, repo_state, pr_metadata)`**, where `pr_metadata`
means GitHub-API authored facts (SHA, base ref, author of each commit) and
explicitly *excludes* the free-text body. Each of the seven artefacts is
the smallest mechanism that breaks one of the five reproduced failure
modes; the set is justified by being the closure of "what would have caught
#411–#414." Designing from the failures avoids the v1 mistake of designing
gates around an idealised PR shape; the v2 substrate is shaped instead
around the malformed PRs that actually got merged. The meta-gate guarantees
the substrate cannot be silently weakened by editing CI itself, closing
the recursion.

## Sketch

### Failure 1 — Gate 5.1 silent-skip when `Gating-test paths` section absent

**Exact reproduction.** `.github/workflows/ci.yml:88-100`:

```yaml
GATING_FILES=$(grep -oP '(?<=`)[^`]+\.exs(?=`)' /tmp/pr-body.txt | sort -u || true)
if [ -z "$GATING_FILES" ]; then
  echo "Gate 5.1: no gating-test paths declared in PR body — skipping."
  exit 0
fi
```

This is the silent-skip path. Confirmed live: PR #411 head SHA
`39f2e4cf4f590de6e38311805224609dea2d155f` shipped with Gate 5.1 logging
"skipping" and exiting 0; mutation-check `SKIPPED` on the same SHA (run
duplicated to confirm). The PR body lists no `Gating-test paths` section
at all; the regex returns empty; the gate exits zero; CI reports green
for Gate 5.1 despite the PR claiming AC advances.

**Catching mechanism (artefact 4 — diff-derived applicability resolver).**
The gate's applicable-input set is the union of:

```
applicable_tests(diff, repo) =
    diff.touched_paths
  ∩ glob(repo, "test/**/*_test.exs")
  ∪ (diff.touched_paths ∩ glob(repo, "lib/**/*.ex")
       |> map(lib_to_test_path)
       |> filter(File.exists?))
```

If `applicable_tests` is empty *and* the diff touches `lib/**/*.ex`, the
gate exits non-zero with `no_gating_test_for_production_diff`. If the diff
touches only `docs/**` or `.github/**`, the gate exits zero with the
explicit verdict `checked, 0 applicable inputs (docs-only diff)` — *never*
"skipping". The PR body's `Gating-test paths` section is removed from the
substrate entirely; the substrate ignores PR-body free text for
applicability decisions.

**Class.** Applicability-from-declaration coupling.

### Failure 2 — Gate 5.2 `|| true` makes masking non-failing

**Exact reproduction.** `.github/workflows/ci.yml:115`:

```yaml
mix tau.gate.masking /tmp/pr-diff.txt || true
```

Whatever `mix tau.gate.masking` returns, the step exits zero. Masking
findings surface as text in the log but are not gate-blocking, by
construction.

**Catching mechanism (artefact 2 — workflow self-check `lint-ci` job).**
A required CI job parses each YAML file under `.github/workflows/` as an
AST (yq + jq, or `ruby -ryaml`) and fails the PR if any of the following
hold on any step that *is required by branch protection* (per artefact 1):

- the step's `run:` block contains the literal token sequence `|| true`,
  `|| :`, `; true`, or `; :` at end-of-line;
- the step declares `continue-on-error: true`;
- the step's `if:` predicate string contains the substring
  `github.event.pull_request.body`;
- the step's `if:` predicate is `false` or a tautological-false expression.

The check is mechanical (string-AST predicates, no heuristics). The
`lint-ci` job itself is in `.github/required-checks.json`; branch
protection requires it; the meta-gate inside it verifies its own listing.
Removing the job from required-checks is itself a PR diff against
`required-checks.json` and is therefore visible.

**Class.** Self-suppression — a gate that cannot fail.

### Failure 3 — PR body cites "verified by `mix ...`" against a red SHA

**Exact reproduction.** PR #413 (head SHA
`f91f7bbdf039bb565d239bc91caf596885807934`) merged with the
`lint (format · credo · compile-warnings)` and `test (Elixir 1.18.1 ·
OTP 27.2)` checks at conclusion `FAILURE`. PR #411 head SHA
`39f2e4cf...` merged with `lint` at `FAILURE` and Gate 5.3 at `FAILURE`.
PR bodies for both cite `mix test` / `mix compile` lines as evidence of
passing gates. Source: `gh pr view <n> --json statusCheckRollup` on each
of #411/#413/#414 — the failure conclusions are durable in the GitHub
API.

**Catching mechanism (artefacts 1 + 3 — required-checks file + head-SHA
evidence binder).** Two halves:

1. *Cannot merge red.* The branch-protection ruleset
   (`infra/branch-protection.json`) lists exactly the set in
   `.github/required-checks.json` as required, with
   `strict: true` (require up-to-date branches) and
   `enforce_admins: true`. A drift-detector job (artefact 5)
   re-fetches `gh api repos/:owner/:repo/branches/main/protection` on
   every PR and fails the PR if the live ruleset differs from
   `infra/branch-protection.json` — admin overrides become a visible
   audit event.
2. *PR-body evidence must be SHA-bound.* The evidence-binder gate
   (artefact 3) scans the PR body for token patterns matching
   `mix test`, `mix compile`, `Finished in`, `tests, 0 failures`, or
   any backtick-fenced block beginning with `$ mix `. For each match,
   the gate requires the same PR body to contain an
   `actions/runs/<id>` URL whose `head_sha` (queried via `gh api`)
   equals `pr.head.sha`. Missing or stale SHA → gate fails.

**Class.** Evidence provenance — local-machine output accepted as proof.

### Failure 4 — Role-separation violation: tau-reviewer authored implementation commits

**Exact reproduction.** Commits on `main` since 2026-05-22:

```
$ git log --format='%h %an' 1174370 5b36184
1174370 tau-reviewer
5b36184 tau-reviewer
```

`1174370` authored by `tau-reviewer` does substantive implementation —
"Collapse init/1 from 259 LOC to 5 LOC", removes ~700 LOC of helpers,
rewrites `put_in`/`get_in` for struct access, introduces a new type
alias. `5b36184` (the `mix tau.gate.*` relocation) is also authored by
`tau-reviewer`. The reviewer-role/implementer-role separation is the
project's primary defence against gate self-certification; v1 dissolved
it silently.

**Catching mechanism (artefact 6 — commit-trailer attestation check).**
For each commit on the PR's head ref (`gh pr view --json commits`):

- Reject if `commit.author.login == "tau-reviewer"` *and* the diff
  touches any path under `lib/`, `test/`, or `web/lib/`. Such commits
  are reserved for `tau-implementer` (or a human, with a `Reviewed-By:`
  trailer attached to a separate review event).
- Reject if a commit message contains `Co-Authored-By: Claude` *and*
  lacks a sibling `Reviewed-By:` trailer naming a different identity
  from the author when the diff touches a `SPEC-*.md` Appendix-B file.
  (Two-eyes invariant on SPEC-protected surfaces.)
- The check runs as a required CI job; the rule set is encoded in
  `infra/commit-roles.json` to keep the substrate declarative.

**Class.** Role-collapse — a single principal both authors and approves
load-bearing changes.

### Failure 5 — Atomic-PR violation: gate-relocate + SPEC-source-map + TUI-revert in one PR

**Exact reproduction.** PR #412 (merge `036fc3b`) diff:

```
lib/mix/gate/ac_linkage.ex                    |  107 ++
lib/mix/gate/common.ex                        |  105 ++
lib/mix/gate/masking.ex                       |   75 ++
lib/mix/gate/mutation.ex                      |  276 +++++
lib/tau/factory/gate.ex                       |  620 -----
docs/spec/SPEC-USER-TURN.md                   |    2 +-
lib/tau/tui/app.ex                            | 1482 ++++++++++++++++++++++++-
lib/tau/tui/app/bootstrap.ex                  |  113 --
lib/tau/tui/app/events.ex                     |  459 --------
[… 7 more lib/tau/tui/app/*.ex deletions …]
```

This PR conflates three distinct concerns: (a) gate-tooling relocation
out of `lib/tau/`, (b) a SPEC source-map edit in
`docs/spec/SPEC-USER-TURN.md`, and (c) reverting #411's TUI-app
decomposition. The PR body title and "## Summary" describe only (a).
The atomic-PR rule (`factory-loop.md` §"PR scope guards") was violated
silently — there is no scope declaration to compare against.

**Catching mechanism (artefact 7 — scope-coherence gate).** The PR body
MUST contain a fenced JSON block:

```json
{
  "scope": {
    "package": "factory.gate-tooling",
    "touched_roots": ["lib/mix/gate/", "lib/mix/tasks/tau.gate.*"],
    "rationale": "Relocate gate tooling out of lib/tau/ namespace"
  }
}
```

The gate parses this JSON (failing the PR if absent/invalid) and
computes `actual_roots = unique_top_level_dirs(diff.touched_paths,
depth=3)`. The PR fails if `actual_roots ⊄ touched_roots` (scope creep)
or if `touched_roots` spans more than one declared `package` in
`infra/scope-packages.json` (a registry of recognised
single-responsibility scopes — `factory.gate-tooling`,
`tui.app-decomposition`, `session.fsm`, `spec.source-map`, etc.).
PR #412 would fail on both counts: the diff touches three packages, and
its declared `touched_roots` would not contain `lib/tau/tui/app/`.

**Class.** Scope-coherence — multi-concern PRs whose declared scope omits
the load-bearing parts.

### Substrate diagram (text)

```
                           ┌──────────────────────┐
                           │ infra/branch-        │
                           │   protection.json    │◄── drift-detector ──┐
                           └──────────┬───────────┘                      │
                                      │ encodes                          │
                                      ▼                                  │
                           ┌──────────────────────┐                      │
                           │ GitHub branch-       │                      │
                           │   protection ruleset │                      │
                           └──────────┬───────────┘                      │
                                      │ requires                         │
                                      ▼                                  │
   ┌───────────────────────────────────────────────────────────┐         │
   │ .github/required-checks.json (authoritative gate list)    │◄────────┘
   │                                                            │
   │  • lint                                                    │
   │  • lint-ci   (meta-gate: workflow YAML self-check)         │
   │  • mutation-check                                          │
   │  • evidence-binder                                         │
   │  • commit-roles                                            │
   │  • scope-coherence                                         │
   │  • binary-qa  …                                            │
   └────┬───────────────────────────────────────────────────────┘
        │ each gate's applicability =
        │   f(diff, repo_state, pr_metadata)
        ▼
   ┌─────────────────────────────────────────────┐
   │ Per-PR run: every gate emits one of         │
   │   • {checked: N applicable, verdict: PASS}  │
   │   • {checked: N applicable, verdict: FAIL}  │
   │   • {checked: 0 applicable, verdict: PASS,  │
   │      reason: "<diff-derived rationale>"}    │
   │   • {infra_failure, verdict: FAIL}          │
   └─────────────────────────────────────────────┘
```

## Tradeoffs

### Strengths

- **Acceptance criterion (a) — silent-skip impossibility — is met by
  construction.** Every gate's applicability is a pure function of
  `(diff, repo_state, pr_metadata)`; the substrate does not read the
  PR-body free text for applicability. A gate with empty applicable input
  emits an explicit `checked, 0 applicable` verdict with a
  diff-derived rationale.
- **Acceptance criterion (b) — meta-gate forbids the workflow
  anti-patterns — is met by the `lint-ci` job operating on AST predicates,
  not regex on log output.**
- **Acceptance criterion (c) — branch protection encoded as artefact and
  drift-detected — is met by `infra/branch-protection.json` plus the
  drift-detector job.**
- **Acceptance criterion (d) — local-mix evidence rejected — is met by
  the evidence-binder gate matching every "mix" claim to a CI run URL
  whose `head_sha` equals the PR head.**
- **Each mechanism has a *named failure on disk* it rejects.** Reviewers
  can verify the mechanism by replaying the exact bad PR (using its
  recorded SHA); a regression-test harness can do this in CI.
- **Reuse-vs-build is explicit and minimal.** Reuses: GitHub Repository
  Rulesets API (artefacts 1+5), `gh api` (artefacts 3+5), `yq`/`jq` (2),
  `git diff --name-only` (4+7). Bespoke: the four gate scripts
  (lint-ci, evidence-binder, commit-roles, scope-coherence) and the two
  JSON registries (`required-checks.json`, `scope-packages.json`).
  Per root §Acceptance D, each bespoke artefact has a one-line "no
  existing tool does this" justification.

### Weaknesses

- **The diff-derived applicability heuristic for AC-binding (artefact 4)
  may produce false-positive `no_gating_test_for_production_diff` rejects
  for legitimate production-only refactors** (e.g. an internal rename
  with no behaviour change). The substrate's escape is an explicit
  `production_only: true` JSON field in the PR-body scope block, gated by
  the scope-coherence rule that such PRs may touch at most one
  `lib/**/*.ex` file. This is narrow and may be too narrow.
- **The commit-roles gate (artefact 6) blocks legitimate cases where a
  human reviewer also implements a fix.** The substrate's escape is a
  `Co-Authored-By: human@…` trailer + manual override label, which
  re-introduces a human-judgement edge. Not zero-discretion.
- **The scope-coherence gate (artefact 7) requires an
  `infra/scope-packages.json` registry that must be maintained as the
  codebase evolves.** A missing entry blocks new work until the registry
  is updated; this is friction by design, but it is real friction.
- **No automated detection of capability-flag lies, contract drift,
  telemetry-consumer absence, NN #7 conformance, or SPEC consistency.**
  Those are owned by `pre-merge-code-gates` and `post-merge-cross-
  artifact-coherence`; this proposal explicitly scopes itself to the
  evidence/skip-integrity dimension. Cross-leaf coordination is required
  for total coverage.
- **`enforce_admins: true` removes the user's ability to merge a hotfix
  past a failing infra job (e.g. a flaky setup-beam action).** The
  mitigation is an in-band "force-merge" workflow that opens a public
  audit issue automatically — non-silent but inconvenient.
- **The substrate increases CI wall-time** by adding 4 new required
  jobs; cold-cache cost is ~30–60s each (lint-ci is YAML parsing only and
  fast; evidence-binder is a single `gh api` round-trip; commit-roles is
  a single `gh api` round-trip; scope-coherence is local).

### Costs

- **Migration cost.** One-time:
  - Write `.github/required-checks.json` and
    `infra/branch-protection.json` and reconcile with current live ruleset
    (~1 day).
  - Implement four mix tasks (`tau.gate.lint_ci`,
    `tau.gate.evidence_binder`, `tau.gate.commit_roles`,
    `tau.gate.scope_coherence`) — pure functions over `gh api` output and
    YAML AST, each ≤200 LOC (~3–4 days).
  - Author `infra/scope-packages.json` for the current ~12 packages
    (~0.5 day).
  - Delete the silent-skip paths in `ci.yml:88-100` and `:213-223`, and
    the `|| true` on `:115`; rewrite Gate 5.1/5.3 to consume
    diff-derived inputs from the resolver (~1 day).
  - Backfill regression tests: one per reproduced v1 failure, each
    asserting "given the recorded bad PR's diff/body/SHA, the substrate
    returns FAIL." Five tests (~1 day).
- **Disruption to consumers.** PR authors must learn the
  `## Scope` JSON block (one paragraph in `factory-loop.md`). Reviewers
  no longer write `Gating-test paths` — net simplification.
- **Knowledge required.** Standard CI/GitHub-API/YAML/jq skills; no new
  runtime, no new dependency on a hosted service. The mix tasks reuse the
  existing `Tau.Factory.Gate.*` modules' style.
- **Test surface impact.** +5 regression tests (one per failure). The
  existing Gate 5.1/5.3 tests in `test/mix/gate/` continue to pass — the
  applicability resolver is layered above them, not in place of them.
- **Build/dependency impact.** Adds `yq` apt install in `lint-ci`
  (negligible). No new mix deps.

## Dependencies

- **Resolution of the `pre-merge-code-gates` and `intent-capture-and-ac-
  binding` siblings.** The applicability resolver (artefact 4) replaces the
  `Gating-test paths` PR-body section; that section is also referenced by
  `factory-loop.md` §"The draft-PR body" and by the AC-binding sibling.
  Coordination required so the three leaves do not redefine the same
  surface incompatibly.
- **GitHub Repository Rulesets API availability for the repo's plan tier.**
  Public repos have it free; the project is public so this is met.
- **`gh` CLI version ≥ 2.40 on CI runners** for the `--json head_sha`
  field in PR status-checks queries. Already met (`ubuntu-24.04` ships
  with 2.40+).
- **`infra/scope-packages.json` registry agreed up-front.** A bootstrapping
  task; without it the scope-coherence gate fails-closed on every PR.

## Confidence

**High.** Confidence basis:

- Every catching mechanism is paired to a named v1 failure with a
  reproducible SHA. The substrate is a regression test against five
  events that *actually happened* in the last 36 hours, not a
  forward-looking guess. Confidence would be raised further by a
  prototype `lint-ci` job and a recorded green-on-good-PR /
  red-on-each-of-#411–#414 regression run.
- The mechanism set is the minimal closure under
  "what would have blocked #411–#414"; it is not aspirational. If a
  sixth failure mode surfaces, the substrate's extension shape is
  already established (add a required check, add it to
  `required-checks.json`, write a regression test against the bad PR).
- The reuse-vs-build axis is conservative: 4 small bespoke gates + 2
  JSON registries on top of GitHub's native ruleset machinery.

## Prior art / references

- **GitHub Repository Rulesets API** —
  `https://docs.github.com/en/rest/repos/rules` — branch-protection-as-
  code is a first-class GitHub primitive; no third-party Terraform
  needed.
- **OpenSSF Scorecard `branch-protection` check** —
  `https://github.com/ossf/scorecard/blob/main/checks/branch_protection.go`
  — independent precedent for treating branch protection as machine-
  checkable artefact (used by Kubernetes, Tekton, …).
- **`gh api repos/:owner/:repo/branches/main/protection`** — already in the
  v1 loop's vocabulary (`factory-loop.md` cycle step 8a); this proposal
  formalises it as a versioned artefact.
- **Sigstore / in-toto attestations** — analogous shape (artefact + check
  registry + verifier) for supply-chain provenance; the
  evidence-binder gate is a degenerate in-toto verifier ("did this CI
  run actually emit the claim cited in the body, on this SHA?").
- **`actionlint`** (`https://github.com/rhysd/actionlint`) — third-party
  GHA YAML linter; the `lint-ci` job could reuse its AST traversal rather
  than re-implementing predicates from scratch (Sketch lists this as a
  reuse candidate; deferred to selector for decision).

---

## Silent-skip impossibility — proof sketch

The substrate's `lint-ci` meta-gate is the chain of trust. The argument:

1. *No required gate may silent-skip.* Every required gate's check
   function has signature `(diff, repo_state, pr_metadata) -> verdict`,
   where `verdict ∈ {pass(applicable_n, reason), fail(applicable_n,
   findings), infra_failure(reason)}`. There is no
   `verdict = skipped` constructor. A gate whose input set is empty
   returns `pass(0, "diff scope <X> excludes this gate's applicability
   set")`. The exhaustiveness check is a static property of the verdict
   sum type, asserted by a unit test in `test/mix/gate/verdict_test.exs`.
2. *The substrate cannot be configured to silent-skip.* The required-
   check list (`.github/required-checks.json`) is itself in the diff;
   removing a check is a visible diff against an artefact the
   scope-coherence gate refuses unless the PR is in package
   `factory.required-checks` (a privileged package whose PRs require
   `Reviewed-By: <human>`).
3. *The substrate cannot be bypassed by an admin merge.* Branch
   protection has `enforce_admins: true` (encoded in
   `infra/branch-protection.json`); the drift-detector job fails the PR
   if the live ruleset differs. An `enforce_admins: false` is itself a
   diff, visible via drift-detector.
4. *The substrate cannot disable itself via `|| true`.* The `lint-ci`
   job's AST check refuses any `|| true` on a required step; the check
   itself is required (recursive case), so disabling it is the same
   diff as removing it from required-checks (case 2).

The set {1,2,3,4} closes the silent-skip surface modulo a human merging
against branch protection by deliberately editing the ruleset on
github.com directly. Drift-detector catches this within the next PR run
and opens an audit issue automatically.

## Class generalisation — what classes the seven artefacts cover

| Class                                                | Artefact(s) | Generalises beyond reproduced failure |
|------------------------------------------------------|-------------|----------------------------------------|
| Applicability-from-declaration coupling              | 4           | Any future gate that "asks the PR body whether to run" — the substrate's signature forbids it |
| Self-suppression (`|| true`, `continue-on-error`)    | 2           | Any future workflow-level escape hatch  |
| Evidence provenance / local-machine evidence         | 1, 3        | Any future PR whose body cites unverifiable claims (test counts, dialyzer summaries, manual replay output) |
| Merge against red CI                                 | 1, 5        | Includes the case where required-checks shrinks silently (drift-detector catches) |
| Role-collapse (reviewer authoring impl)              | 6           | Any future role expansion — add the role to `infra/commit-roles.json`; check covers it |
| Scope-coherence violations / atomic-PR violations    | 7           | Any multi-concern PR whose scope JSON misrepresents the diff |

The seven artefacts are a covering set, not a one-to-one map. The
generalisation is that the substrate treats every gate as a pure function
over machine-readable inputs and rejects every channel by which a PR body
could weaken the gate's verdict.
