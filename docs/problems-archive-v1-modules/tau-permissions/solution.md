---
template_version: 1
template_name: solution
parent_problem: problem.md
node_kind: root
synthesised_from:
  - subproblems/matcher-unit-contracts/solution.md
  - subproblems/mode-lattice-properties/solution.md
  - subproblems/evaluator-mode-complecting/solution.md
  - subproblems/settings-merge-feed/solution.md
selection_method: synthesis
mode: non-leaf
revision: 0
---

# Solution: Close tau-permissions property-coverage holes and decomplect evaluator mode-dispatch via four layered, parallelisable PRs

## Recommendation

Land four independently-reviewable PRs, one per concern layer, that together
satisfy the root acceptance criterion. The PRs are disjoint in source ownership
and may be authored and gated concurrently (see Parallelism below), but the
evaluator-mode PR carries a single shared interface point — a SPEC amendment in
`SPEC-PERMISSION-PROMPTS.md` that introduces one new D-NNN invariant — which
gates the synthesis as a whole. Layer responsibilities are: (PR-A)
`test/tau/permissions/matchers_test.exs` plus the 3-line `PathPrefix.match?/4`
fail-closed purification; (PR-B) exhaustive 9-pair `clamp/2` sweep and an
`at_or_below?/2` property block in `test/tau/permissions/mode_test.exs`; (PR-C)
extraction of `Tau.Permissions.ModePolicy` with a delegated `default_for_mode/3`
plus `test/tau/permissions/mode_policy_test.exs` properties and the new D-NNN
SPEC entry; (PR-D) `test/tau/settings/loader_property_test.exs` covering the
three permissions-array merge invariants. After all four land, every
invariant-bearing function in `tau-permissions` and `Settings.Loader.merge/2`
has at least one property test, the `PathPrefix` impurity is eliminated rather
than merely documented, and the evaluator's per-mode allow-set is structurally
separated from rule-set precedence and pinned by a spec-gated D-NNN.

## Selected from

- **Synthesised from:**
  - `subproblems/matcher-unit-contracts/solution.md` — StreamData properties
    for all five matchers + purify `PathPrefix.match?/4` (hybrid P2+P3).
  - `subproblems/mode-lattice-properties/solution.md` — deterministic 9-pair
    `for` sweep + `at_or_below?/2` property block (single P2).
  - `subproblems/evaluator-mode-complecting/solution.md` — extract
    `Tau.Permissions.ModePolicy` + pin D-NNN in spec (hybrid P2+P4).
  - `subproblems/settings-merge-feed/solution.md` — new
    `loader_property_test.exs` with three merge invariants (single P2).

- **Composition rationale:** the four child solutions partition cleanly by
  concern layer; their `What changes` lists are file-disjoint (`matchers.ex` +
  `matchers_test.exs` / `mode_test.exs` / `mode_policy.ex` + `evaluator.ex` +
  `mode_policy_test.exs` + `SPEC-PERMISSION-PROMPTS.md` / `loader_property_test.exs`)
  and their failure modes are orthogonal. There is no conflict to resolve and
  no gap against the root acceptance criterion: matcher-unit-contracts covers
  the five matchers and the `PathPrefix` impurity concern explicitly (the root
  AC names the latter as a "documented known deviation" — the synthesis
  upgrades that to "eliminated" via PR-A's hybrid, which is strictly stronger
  and satisfies the AC by removing the deviation rather than documenting it);
  mode-lattice-properties closes the peer-rank gap; evaluator-mode-complecting
  delivers the structural decomplecting demanded by the AC's third clause;
  settings-merge-feed closes the upstream-feed gap on `Loader.merge/2`. The
  only cross-layer interface is the SPEC-gating discipline: PR-C's D-NNN entry
  in `SPEC-PERMISSION-PROMPTS.md` is the durable anchor for the whole
  subsystem's invariant set and is the only file touched outside `lib/tau/` and
  `test/`. No child's recommendation contradicts another. PR-A's
  `PathPrefix` purification (one of two production-code changes in the whole
  set) is independent of PR-C's `ModePolicy` extraction (the other), so the two
  may merge in either order.

## What changes

Concrete file-level list, grouped by PR. Each PR is self-contained and gated
independently.

### PR-A — matcher unit contracts + purify `PathPrefix`

- **New file** `test/tau/permissions/matchers_test.exs` — StreamData property
  tests for `Always`, `Glob` (incl. `glob_match?/2`), `PathPrefix`, `Domain`,
  `Regex`; two or more properties per matcher plus boundary examples.
- **Modified** `lib/tau/permissions/matchers.ex` — `PathPrefix.match?/4`:
  replace `cwd = ctx[:cwd] || File.cwd!()` with a `case ctx[:cwd]` that returns
  `false` when `nil` (fail-closed); update `PathPrefix` moduledoc to state the
  now-pure contract.
- **Pre-PR audit** (no file change): grep all `Evaluator.evaluate/5` call sites
  to confirm `:cwd` is in the ctx map; any gap fixes land in the same PR.

### PR-B — mode-lattice peer-rank exhaustion + `at_or_below?/2` properties

- **Modified** `test/tau/permissions/mode_test.exs`:
  - remove the three spot-check tests inside
    `describe "clamp/2 — peer modes"`;
  - add `@peers [:accept_edits, :dont_ask, :plan]` at the top of the property
    section;
  - add `describe "clamp/2 — peer modes (exhaustive 9-pair sweep)"` with one
    `test` doing `for req <- @peers, par <- @peers, do: assert
    Mode.clamp(req, par) == req` (interpolated error message on failure);
  - add `describe "at_or_below?/2 — properties"` with a StreamData reflexivity
    property and two `FunctionClauseError` guard tests.

### PR-C — extract `ModePolicy` + pin D-NNN invariant

- **New file** `lib/tau/permissions/mode_policy.ex` — `Tau.Permissions.ModePolicy`
  module with `@policies` compile-time map, `%ModePolicy{}` struct
  (`allow_set`, `default_outcome`, `bash_heuristic?`), `default/3`, and
  `for_mode/1`. `allow_set: :all` handled as a tagged-union variant with an
  explicit type annotation (`[String.t()] | :all`) or a dedicated `bypass`
  arm — implementer chooses.
- **Modified** `lib/tau/permissions/evaluator.ex` — replace the six
  `defp default_for_mode` clauses with a single-clause delegation
  `defp default_for_mode(mode, tool, args), do: ModePolicy.default(mode, tool, args)`.
- **New file** `test/tau/permissions/mode_policy_test.exs` — StreamData
  properties targeting `ModePolicy.default/3` directly: `:plan` denies outside
  allow-set; `:dont_ask` denies all; `:auto` never allows outside allow-set;
  `:accept_edits` non-Bash non-allowed tools yield `:ask`.
- **Modified** `docs/spec/SPEC-PERMISSION-PROMPTS.md` — add one D-NNN
  invariant entry (next free slot in D-090..D-099 — must be confirmed by
  `git log --all --grep` plus `grep -rn` over `lib test docs .claude` before
  filing) stating the `ModePolicy` contract, the allow-set table,
  ADR-0014/ADR-0015 citations, `"Agent"` exemption rationale, the
  `:accept_edits` Bash exception, and naming `mode_policy_test.exs` as
  enforcement.

### PR-D — settings-merge feed properties

- **New file** `test/tau/settings/loader_property_test.exs` — three property
  tests with `fixed_map/1`-based local generators (`permission_list/0`,
  `permissions_layer/0`, `settings_with_permissions/0`):
  - C1: prefix-then-suffix concatenation invariant for `allow` / `deny` / `ask`
    simultaneously;
  - C2: right-identity `merge(x, %{}) == x`;
  - C3: absent-key-as-empty-list invariant.
  - Module: `Tau.Settings.LoaderPropertyTest`.

## What does not change

- `Tau.Permissions.Matcher` behaviour interface (`match?/4` signature
  unchanged across all PRs).
- `Evaluator.evaluate/5` public signature (PR-C delegates `default_for_mode/3`
  internally; the rule-set scan logic, priority order, and call signature are
  preserved).
- `Tau.Permissions.RuleSet` lifecycle — no GenServer / PubSub /
  `:persistent_term` changes; explicitly out of scope per the root problem.
- `Tau.Permissions.Matchers.Always` — no `{:only, tool}` extension (Proposal 3
  of the evaluator sub-problem was rejected for cost).
- No new matcher modules.
- `lib/tau/settings/loader.ex` — no production changes from PR-D (only new
  tests; if C1/C2/C3 reveal a bug, that becomes a separate fix per the
  sub-problem's open question).
- `lib/tau/permissions/mode.ex` — no production changes from PR-B (test-only).
- `test/tau/permissions/evaluator_test.exs` — existing indirect coverage is
  preserved across PR-A and PR-C.
- `mix.exs` — `stream_data` already present; no dependency changes.
- ADR-0013/0014/0015 — no contract changes; PR-C's SPEC entry cites the ADRs
  rather than amending them.
- All SPECs other than `SPEC-PERMISSION-PROMPTS.md` (the sole spec touch lives
  in PR-C).
- The `:awaiting_permission` FSM state and TUI permission dialog (owned by
  `Tau.Session` / `Tau.TUI.App`) — explicitly out of scope.

## Migration sketch

The four PRs are parallelisable per the conflict check in
`.claude/rules/factory-loop.md` §Parallel execution. Walk the five clauses:

1. **No dependency** — none of the four blocks any other; PR-C's SPEC entry is
   the only durable cross-PR artefact and it does not block PR-A / PR-B / PR-D
   landing.
2. **Disjoint files** — verified above; the four `What changes` lists do not
   share a single file path (PR-A and PR-C both write under
   `lib/tau/permissions/` but to disjoint files; PR-A touches `matchers.ex`,
   PR-C touches `evaluator.ex` and creates `mode_policy.ex`; the only shared
   directory is `test/tau/permissions/` but each PR's new test file is
   distinct).
3. **Disjoint codepoints** — verified: PR-A modifies one function in
   `matchers.ex` (`PathPrefix.match?/4`); PR-C modifies `default_for_mode/3` in
   `evaluator.ex`; no overlap.
4. **No shared SPEC or D-NNN block** — only PR-C touches a SPEC; the D-NNN it
   adds is a new slot in D-090..D-099, not an amendment to an existing entry.
5. **Shared-resource isolation possible** — none of the four PRs exercises
   `mix release` / `mix tau.smoke` / Burrito; standard `mix test` per-worktree
   isolation suffices.

All five clauses clear. The recommended factory batch is to spawn PR-A, PR-B,
PR-C, PR-D concurrently as four implementer agents, each `isolation: worktree`,
each with its own draft PR opened first per the factory-loop cycle. Merges
serialise (one at a time) and each merge fires the freshness re-check for the
others; expect three rebases over the batch's lifetime. If the coordinator
cannot gate four concurrent PRs without losing track, serialise to two batches
(PR-A + PR-B first; PR-C + PR-D second; the recommended preferential order
within either grouping is alphabetical, no technical ordering forces a
sequence). The full set should close in one factory cycle for the assigned
milestone.

## Open questions

- **D-NNN slot for PR-C.** The next free identifier in D-090..D-099 must be
  confirmed by `git log --all --grep <id>` plus `grep -rn <id> lib test docs
  .claude` before PR-C is filed. The sketch uses a placeholder; the
  implementer's first task in PR-C is the grep.
- **`allow_set: :all` type for `:bypass`.** PR-C must choose between a tagged
  union (`[String.t()] | :all`) and a dedicated `bypass_policy` field on
  `%ModePolicy{}` to satisfy Dialyzer. Either is acceptable; the choice is
  local to PR-C.
- **`mode_policy_test.exs` placement.** Either a new file or a `describe` block
  inside `evaluator_test.exs`; the SPEC's enforcement line in PR-C must name
  whichever is chosen.
- **Call-site audit scope for PR-A.** `Tau.Session` must populate `:cwd` in the
  ctx it passes to `Evaluator.evaluate/5` for the `PathPrefix` purification to
  be safe at every call site. If the audit surfaces a gap, the ctx-population
  fix lands in the same PR-A; this slightly widens PR-A's scope but does not
  break the conflict check.
- **Generator widening for PR-A.** `Domain` properties currently miss Unicode
  hostnames / IDNs; `Glob.glob_match?/2`'s `?` / `/` behaviour is documented
  by the property suite but not changed. Both are explicit residuals of the
  child solution and remain open.
- **C3 outcome for PR-D.** If the absent-key property fails against the real
  `Loader.merge/2`, the implementer must either fix the loader (which widens
  PR-D's scope) or narrow the property and file a follow-up. The sub-problem
  treats this discovery as the value of the property suite.
- **Deferred deeper structural fix for evaluator.** Proposal 3 of the
  evaluator sub-problem (folding mode defaults into the rule-set itself)
  remains the correct long-term direction. It is explicitly deferred and
  should be filed as a follow-up issue against `SPEC-PERMISSION-PROMPTS.md`
  once the `:accept_edits` Bash matcher design is settled.

## Linked sub-problems / proposals

- `subproblems/matcher-unit-contracts/` → "StreamData property tests for all
  five matchers + purify `PathPrefix.match?/4` fail-closed when `ctx[:cwd]` is
  absent" (hybrid P2 + P3).
- `subproblems/mode-lattice-properties/` → "Deterministic 9-pair `for`
  comprehension peer-mode sweep + dedicated `at_or_below?/2` property block in
  `mode_test.exs`" (single P2).
- `subproblems/evaluator-mode-complecting/` → "Extract `Tau.Permissions.ModePolicy`
  data structure and delegate `default_for_mode/3`; pin a new D-NNN invariant in
  `SPEC-PERMISSION-PROMPTS.md`" (hybrid P2 + P4).
- `subproblems/settings-merge-feed/` → "New `loader_property_test.exs` with
  three properties (concat, right-identity, absent-key)" (single P2).

## Revision history

- (revision 0 — initial)
