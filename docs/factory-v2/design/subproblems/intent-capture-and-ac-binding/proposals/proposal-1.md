---
template_version: 1
template_name: proposal
proposal_id: 1
parent_problem: ../problem.md
method: first-principles-design
---

# Proposal 1 — Structured AC binding manifest + per-AC call-site mutation

## One-line

Make the PR's acceptance-criteria block a **machine-typed manifest** that names
the user-path entry point and the gating test for each AC, then prove the
binding by **mutating that exact call site** (not the whole tree) and asserting
the named test goes red.

## First-principles derivation

The failure class is: a test invokes the wrong layer (helper, struct, private
function) while declaring it advances an AC about the user-facing path. Two
independent things must hold for that to remain impossible:

1. **The user-facing path must be named in a machine-resolvable form.** Prose
   ("the headless `tau run` path") is not resolvable. A symbol
   (`Tau.CLI.main/1`) or a CLI argv pattern (`tau run --system-prompt-file *`)
   is resolvable: a compiler / shell can answer "does this exist."

2. **The test that proves the AC must demonstrably depend on that exact
   user-path call site.** A test that doesn't notice when the user-path call
   site is disabled is, by construction, exercising something else. The
   minimum-mechanism proof is per-AC mutation: silence the named call site,
   re-run only the named gating tests, require ≥1 to fail.

Everything else is glue: a schema for the manifest, a mix task that runs the
proof, a CI gate that blocks merge, and silent-skip semantics that turn
"nothing to check" into an explicit verdict ("checked, no applicable
findings") rather than a missing job step.

## Components

Each component is named with the concrete file path it would live at.

### C1 — PR-body AC manifest schema

- **Path:** `.github/PULL_REQUEST_TEMPLATE.md` (the human-facing template) +
  `lib/tau/factory/ac_manifest.ex` (the parser/validator) +
  `priv/factory/ac_manifest.schema.json` (the JSON Schema the parser enforces).
- **Input:** the PR body text fetched via `gh pr view <n> --json body`.
- **Output:** a typed struct list `[%Tau.Factory.ACManifest.Entry{
    id: "AC-B6",
    user_path: {:elixir_mfa, Tau.Session, :set_permissions_mode, 2}
              | {:cli_argv, ["run", "--system-prompt-file", :_]}
              | {:meta, "verified-by-ci-wiring"},
    gating_tests: ["test/tau/session_permission_test.exs:42",
                   "test/tau/session_permission_test.exs:88"]
  }, ...]` plus a list of parse errors (with line numbers in the PR body).
- **Failure mode:** any AC token in the `## Acceptance criteria` section that
  the parser cannot resolve to a complete entry returns `{:error, ...}` with
  the failing token. Non-meta entries that omit `user_path` or `gating_tests`
  are parse errors, not warnings.
- **Gating effect:** none directly; C1 is a library. Its output feeds C2 and
  C3. But because it is a strict parser with a single typed output, every
  downstream gate keys on the same source of truth — divergence between gates
  on what the AC "claims" becomes impossible.

The schema is deliberately minimal — id, user_path tagged tuple, gating_tests
list, optional `meta: true` marker. Meta-ACs (e.g. an AC satisfied by CI
wiring) are explicit and must declare `meta: true`; the gate then asserts the
*CI workflow file* contains the named step, not a unit test.

### C2 — `mix tau.gate.ac_binding`

- **Path:** `lib/mix/tasks/tau.gate.ac_binding.ex` (new) — pairs with the
  existing `tau.gate.ac_linkage`, `tau.gate.masking`, `tau.gate.mutation`.
- **Input:** PR number (from `GITHUB_REF` / `gh` env); reads PR body via
  `gh pr view`, parses via C1.
- **Output:** structured verdict to stdout (JSON) and exit code:
  - `exit 0` + `{"status":"pass", "checked": N, "skipped": 0}` — every
    non-meta entry's user_path resolved to a symbol that exists, and the
    per-AC mutation proof (C4) returned `:demonstrated`.
  - `exit 0` + `{"status":"no_applicable", "reason":"no_AC_tokens_in_body"}` —
    body has no `## Acceptance criteria` section AND PR is labeled
    `chore:no-ac` (typo fix / dep bump / formatting). Both conditions
    required; only the *label* lets the verdict be "no applicable"; absence
    of the section without the label is a fail.
  - `exit 1` + `{"status":"fail", "findings":[...]}` — any unresolved
    user_path, any non-meta AC with no gating_tests, any per-AC mutation that
    failed to demonstrate dependency.
  - `exit 2` + `{"status":"infrastructure_fail", "reason":"..."}` — `gh`
    unreachable, repo not on the PR's HEAD, etc. This is *not* a pass; the
    CI gate (C5) treats exit 2 as failing the PR.
- **Failure mode:** any non-passing exit blocks merge via C5.
- **Gating effect:** binding contract enforcement.

### C3 — `Tau.Factory.UserPathResolver`

- **Path:** `lib/tau/factory/user_path_resolver.ex` (a pure module, no
  process).
- **Input:** the `user_path` tagged tuple from C1.
- **Output:** `{:ok, %ResolvedPath{}}` carrying enough information for C4 to
  perform the mutation — for `:elixir_mfa`, a `{module, fun, arity}` tuple
  the compiler has confirmed exists at HEAD; for `:cli_argv`, a list of
  `Tau.CLI` dispatch clauses (resolved by `Code.fetch_docs/1` + AST grep on
  `lib/tau/cli.ex`) the argv matches. For `:meta`, no resolution attempted
  — C2 instead checks the named workflow file/step exists.
- **Failure mode:** `{:error, :symbol_not_found, ...}` if the MFA doesn't
  exist, the arity is wrong, the function is `defp`, or no `Tau.CLI` clause
  matches the argv pattern. This *is* the AC-side contract drift check
  (failure class #1, AC-side): an AC that cites a symbol the codebase
  doesn't have fails at C3 and the PR cannot pass C2.
- **Gating effect:** prevents AC text from naming nonexistent symbols.

### C4 — `Tau.Factory.CallSiteMutator`

- **Path:** `lib/tau/factory/call_site_mutator.ex` (pure module) + a
  per-mutation scratch worktree managed by C2.
- **Input:** a `%ResolvedPath{}` (from C3) plus the gating-test list.
- **Output:** `:demonstrated | {:not_demonstrated, [test_id]}`.
- **Algorithm (per AC, isolated):**
  1. Spawn an ephemeral git worktree at `tmp/factory/ac-binding-<sha>-<id>/`.
  2. Apply *one* of these AST rewrites (chosen by `user_path` tag):
     - `:elixir_mfa` — rewrite the named function in its host module to
       raise `Tau.Factory.MutationMarker, "AC-N call site disabled"` as the
       first expression. (Not delete; raising is more diagnostic than a
       silent no-op and survives default-argument re-writes.)
     - `:cli_argv` — rewrite the matched `Tau.CLI` dispatch clause body to
       raise the same marker.
     - `:meta` — N/A; C2 short-circuits.
  3. `mix compile --warnings-as-errors` (must succeed; if not, the AC's
     gating_tests are malformed against the manifest — verdict
     `:not_demonstrated` with reason `:compile_failed`).
  4. Run only the named gating tests with `mix test <files-and-lines>`.
  5. Demonstrated iff ≥1 named test fails AND the failure stack includes
     `Tau.Factory.MutationMarker`. The marker check defeats "the test
     fails for a coincidental reason."
  6. Tear down the worktree (capture-before-destroy per
     `worktree-discipline.md` if mutation left artefacts, otherwise plain
     `git worktree remove -f -f`).
- **Failure mode:** any `:not_demonstrated` makes C2 fail the PR.
- **Gating effect:** the proof. This is the structural-impossibility piece:
  a test that exercises the wrong layer *cannot* notice the call-site
  mutation, and so cannot pass.

C4 differs from the existing `mix tau.gate.mutation` (which reverts
everything-not-in-gating-test-paths to merge-base) in two essential ways:
(a) it targets the *single call site* the AC names, not the whole production
diff, so it isolates the question "does this test depend on this entry
point" from "does this test depend on anything that changed in this PR";
(b) it ties the failure signal to a marker raise, so a test that fails for
a coincidental compile-time error is not credited as "demonstrated."

### C5 — CI workflow gate

- **Path:** `.github/workflows/ci.yml` (new job: `ac_binding`).
- **Input:** the PR ref and number.
- **Output:** a required GitHub status check. The job runs:
  ```yaml
  - name: AC binding
    run: mix tau.gate.ac_binding --pr ${{ github.event.pull_request.number }}
    # NO `|| true`, NO `continue-on-error`, NO `if:` early-exit guard.
  ```
- **Failure mode:** non-zero exit fails the job; the branch protection rule
  on `main` requires this job to pass before merge.
- **Gating effect:** the actual blocker. C2 produces the verdict; C5 is what
  turns the verdict into a merge block.

The job has no `if:` guard. Even a "trivial typo fix" PR runs the job;
the `chore:no-ac` label path is handled by C2 returning `pass` with
`status: no_applicable`, **not** by the workflow skipping the job. This is
the silent-skip-impossibility mechanism: the gate runs unconditionally,
and "nothing to check" is a verdict the gate produces, not the absence of
a verdict.

### C6 — Branch protection wiring

- **Path:** `.github/settings.yml` (if using probot/settings) OR a documented
  one-shot script `scripts/factory/configure-branch-protection.sh` invoking
  `gh api repos/.../branches/main/protection`.
- **Input:** repo admin token, list of required checks.
- **Output:** branch protection on `main` requiring `ac_binding` (and the
  other gates from sibling proposals) to pass before merge.
- **Failure mode:** if the script has not been run, this proposal's gate
  isn't actually blocking. C6 is a one-time bootstrap, but its absence is
  detectable: the operability sibling's dashboard reads
  `gh api .../branches/main/protection` and reports missing required checks.
- **Gating effect:** binds C5's status check to merge.

### C7 — Manifest authoring helper agent

- **Path:** `.claude/plugins/factory-v2/agents/ac-manifest-author.md` +
  `.claude/plugins/factory-v2/skills/ac-manifest/SKILL.md`.
- **Input:** the issue body + the in-scope SPEC sections + the open PR
  draft.
- **Output:** a proposed `## Acceptance criteria` block in the manifest
  schema (C1), inserted into the draft PR body via `gh pr edit`.
- **Failure mode:** if the agent produces a manifest that doesn't parse
  (C1) or doesn't resolve (C3), C2 fails the PR. The agent's output is
  never load-bearing — it's a typing aid for humans / implementers, and
  the mechanism (C2-C5) is what enforces correctness. An agent that
  hallucinates a `user_path` is caught by C3.
- **Gating effect:** none — quality-of-life only. Listed explicitly so the
  proposal does not appear to assume an agent does the work.

## Silent-skip impossibility — concrete return semantics

The "nothing to check" question has exactly two legitimate answers:

- The PR body has no `## Acceptance criteria` section AND the PR carries
  the `chore:no-ac` label (added by a human reviewer or the
  `tau-github-workflow` triage step). C2 returns `pass` with
  `{"status":"no_applicable", "reason":"chore_no_ac_label"}`. The CI
  status is green; the verdict is recorded as "checked, no applicable
  findings."

- The section is present and parses. C2 runs C3 + C4 for every entry and
  returns `pass` or `fail`.

Every other state — missing section without label, section that doesn't
parse, entry without `user_path`, entry without `gating_tests`,
unresolvable `user_path`, mutation that doesn't demonstrate — is a **fail**.
There is no codepath in C2 that exits 0 without writing a verdict to
stdout.

The verdict is emitted in two places: stdout (read by CI to set the check
status) and a JSON file at `tmp/factory/verdicts/ac_binding-<sha>.json`
(uploaded as a CI artifact). The artifact path is what the operability
sibling's dashboard reads.

## How the verdict is consumed

- **GitHub status check `ac_binding`** — read by branch protection (C6)
  to gate merge; read by humans on the PR page.
- **CI artifact `verdicts/ac_binding-<sha>.json`** — read by the
  operability sibling's dashboard to render per-PR gate health; read by
  the post-merge cross-artifact sibling on `main` to populate a historical
  series (which AC tokens have churned, which surfaces accumulate AC
  fails).
- **PR body update** — C5's job appends a structured block at the end of
  the PR body via `gh pr comment` (not `gh pr edit`, to preserve the
  manifest section as the single source of truth): one comment per gate
  run, with the verdict JSON inline. This is what humans see at a glance
  and what the critic/reviewer gates read when forming their (non-load-
  bearing) commentary.

## Failure classes addressed

- **#6 primary** — per-AC call-site mutation (C4) is the structural
  proof that a test exercises the path the AC names. A wrong-path test
  cannot pass.
- **#1 AC-side** — `UserPathResolver` (C3) fails AC text that cites
  nonexistent symbols or argv patterns. AST-level drift in production
  code remains with the pre-merge-code-gates sibling.

## How each AC of the leaf is satisfied

- **(a) every AC-N / D-NNN paired with user-path entry point and
  gating-test paths.** C1's schema makes this a parse error otherwise; C2
  refuses to pass on parse errors.
- **(b) per-AC mutation that disables the specific user-path call site;
  named test(s) MUST go red.** C4 implements exactly this, with the
  marker-raise check defeating coincidental failures.
- **(c) cannot silent-skip.** C5 runs unconditionally; C2's only "no
  applicable" path requires an explicit label.
- **(d) reuse-vs-build recorded.** Explicit decision: bespoke. Rationale:
  `muzak` mutates all-of-tree non-deterministically and reports
  surviving mutants; we need per-AC, single-call-site mutation with a
  named marker. Adapting `muzak` to drive named mutations is more code
  than C4. `excoveralls` coverage answers "did the test touch the line,"
  not "does the test depend on the line"; coverage is necessary but not
  sufficient and so would not satisfy AC-B6. The reuse-survey-of-record
  is proposer 2's responsibility; this proposal records its own decision
  here.
- **(e) concrete artifacts named.** Listed above with file paths.

## Build-order

**Week 1 — minimum viable gate, end-to-end:**

1. C1 (`Tau.Factory.ACManifest`) — schema + parser + tests. No other
   component compiles without it.
2. C3 (`Tau.Factory.UserPathResolver`) — resolution for `:elixir_mfa` only
   in week 1; `:cli_argv` deferred to week 2. This is enough to bind any
   AC that names an Elixir function.
3. C2 (`mix tau.gate.ac_binding`) — stub C4 to always return
   `:demonstrated` in week 1. The gate enforces parse + resolve only.
4. C5 (CI workflow step) — wired to run C2 on every PR.
5. C6 (branch protection) — required check set.

End of week 1: a PR with an unresolvable AC fails to merge. A PR with no
AC section and no label fails to merge. Silent-skip impossible.

**Week 2 — close the AC-B6 hole:**

6. C4 (`CallSiteMutator`) — `:elixir_mfa` rewrite path with marker raise.
   C2 stops stubbing.
7. C3 — add `:cli_argv` resolution (argv pattern → `Tau.CLI` dispatch
   clauses).
8. C4 — `:cli_argv` rewrite (target the matched clause body).

End of week 2: AC-B6 falsification probe is mechanically prevented. The
existing `tau.gate.mutation` becomes redundant for AC scope and can be
retired (decision deferred to the pre-merge-evidence sibling, which owns
the gate inventory).

**Week 3 — affordances:**

9. C7 (manifest-author agent + skill) — typing aid for implementers.
   Non-load-bearing; pure DX.
10. Meta-AC support — `:meta` tag in C1, CI-workflow-step check in C2.

## Dependencies

- **Outbound:** none from sibling design proposals; this leaf is
  self-contained.
- **Inbound:** the pre-merge-evidence sibling's "no silent-skip" mechanism
  may want to wrap *all* gate workflow steps with a common runner that
  forbids `continue-on-error`; C5 written as above is conformant. The
  operability sibling consumes the JSON artifact.
- **Tooling:** `gh` CLI in CI (already present); `mix` in CI (already
  present); a per-job throwaway worktree (C4) — fits the existing
  `worktree-discipline.md`.

## Confidence

Medium-high. The mechanism is small (≈400 LoC across C1-C4) and each
component is independently testable. The principal risk is C4's
`:cli_argv` rewrite: matching argv patterns against `Tau.CLI` dispatch
clauses requires either a structured router (which `Tau.CLI` doesn't
currently have — it's a flat `case` in `main/1`) or AST pattern matching
against the argv literal. The `:elixir_mfa` path is straightforward and
covers the audit's named falsification probe (AC-B6) immediately;
`:cli_argv` is the harder week-2 work and the place to expect rework.

## What this proposal explicitly does not do

- Does not survey ecosystem alternatives (proposer 2).
- Does not lift a prior-art mechanism wholesale (proposer 3).
- Does not derive components by reverse-engineering specific past PR
  failures (proposer 4).
- Does not touch AST checks on production code (sibling
  pre-merge-code-gates).
- Does not touch the gate-infrastructure invariants of no-silent-skip
  *for other gates* (sibling pre-merge-evidence-and-skip-integrity) —
  only this gate's own no-silent-skip semantics.
- Does not modify `tau.gate.mutation`; that is in scope for the
  pre-merge-evidence sibling to retire or repurpose.
