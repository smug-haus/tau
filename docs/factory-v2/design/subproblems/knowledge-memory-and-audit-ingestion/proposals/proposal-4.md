---
template_version: 1
template_name: proposal
proposal_id: 4
parent_problem: ../problem.md
---

# Proposal 4: Adversarial — registry as a closed loop of constructed-failure probes

## Approach

Treat the audit-ingestion registry not as a passive lookup of "what was
written down" but as a closed loop in which each registered finding is
accompanied by an **executable falsification probe** — a one-shot
adversary test that the registry runs against every PR diff, plus
nightly against `main`. A finding without a probe is rejected at
authoring time; a probe that does not currently fail against the named
pre-remediation revision is rejected at authoring time; a probe whose
green-on-main run rate drops below 100% halts the loop. Three artifacts
carry the design: (a) `priv/audit/findings/<id>.yml` — structured
frontmatter plus a `probe:` field naming a Mix-task probe module; (b)
`Tau.Factory.AuditRegistry` — supervised GenServer that loads findings
at boot, computes per-PR applicability from the diff ∩ surface
manifest, and dispatches the probe; (c) `mix tau.audit.compile` — a
CI-blocking task that, for every `open` finding, asserts the probe
module exists, exports `run/1`, and was demonstrated to fail at the
finding's `proven_at_sha` (a required field). The registry never trusts
"the finding is written" — it trusts only "the probe currently
detects the violation it claims."

## Rationale

The complecting hypothesis names three threads: "finding exists" ≠
"enforcement exists"; "remediation" ≠ "audit closed"; "which gate
runs on which PR" ≠ "the diff". Proposals 1–3 (assumed: structured-
frontmatter / credo-check / SARIF) decomplect the first by giving
findings a schema, but they all leave the second and third under
human discipline: a check that *exists* may *no longer detect*
anything (the code shape it watched for was renamed), and a finding
flipped to `remediated` may have been flipped without the probe ever
turning red. Adversarial registration closes both: a probe with a
`proven_at_sha` is provably load-bearing at registration; a probe that
goes green on `main` when the finding is still `open` halts the loop,
forcing the author to either re-prove the violation or flip the
status with evidence. This is the same property the v1 mutation-check
provides for AC-bearing tests, generalised to audit findings. It also
folds failure-class #10 into the same enforcement substrate the
pre-merge-code-gates sibling already needs.

## Sketch

**Finding frontmatter** (`priv/audit/findings/F-007-port-lifecycle-rescue.yml`):

```yaml
finding_id: F-007
title: "Port lifecycle wrapped in rescue clause"
authored_at: 2026-05-21
status: open                 # open | remediated | waived
proven_at_sha: 7c4ad9e2      # SHA at which the probe demonstrably failed
surface:
  paths:
    - "lib/tau/coding_agent/**/*.ex"
    - "lib/tau/tools/builtin/**/*.ex"
  ast_patterns:
    - "Port.open/2 within try/rescue"
invariant: "NN #7 — no try/rescue across process boundaries"
probe: Tau.Factory.Audit.Probes.PortLifecycleRescue
remediation_pr: null
waiver:
  expires_at: null
  rationale: null
prior_audit_ref: "docs/problems-archive-v1-modules/tau-coding-agent/rescue-sites.md#L42"
```

**Probe module** (`lib/tau/factory/audit/probes/port_lifecycle_rescue.ex`):

```elixir
defmodule Tau.Factory.Audit.Probes.PortLifecycleRescue do
  @behaviour Tau.Factory.Audit.Probe

  @impl true
  def applicable?(diff), do:
    Tau.Factory.Diff.intersects?(diff,
      ["lib/tau/coding_agent/**/*.ex", "lib/tau/tools/builtin/**/*.ex"])

  @impl true
  def run(_ctx) do
    case Tau.Factory.AST.find(
           globs: ["lib/tau/coding_agent/**/*.ex", "lib/tau/tools/builtin/**/*.ex"],
           pattern: {:rescue_around, :"Port.open"}) do
      []        -> :ok
      [_ | _] = hits -> {:violation, %{hits: hits, finding_id: "F-007"}}
    end
  end
end
```

**Registry GenServer signatures** (`lib/tau/factory/audit/registry.ex`):

```elixir
@spec for_pr(pr_number :: integer, diff :: Diff.t()) ::
        [%Finding{}]
@spec dispatch(pr_number, diff) :: %{
        ran: [finding_id],
        violated: [%Violation{}],
        waived_active: [%Finding{}],
        waived_expired: [%Finding{}]
      }
@spec health() :: %{
        open: non_neg_integer,
        probes_green_on_main_but_open: [finding_id],  # halts loop if non-empty
        waivers_expiring_within_7d: [finding_id]
      }
```

**CI wiring** — three new gates, none silent-skippable:

1. `mix tau.audit.compile` (PR + main) — exits non-zero if any
   `open` finding lacks a `probe:` module that exports `run/1`, or if
   any `proven_at_sha` does not produce a `:violation` when the probe
   is run against that historical tree.
2. `mix tau.audit.gate` (every PR) — runs every applicable open
   probe; fails the PR on any `:violation`; emits
   `{ran: [...], violated: [...], skipped: []}` — `skipped` is always
   empty by construction (a probe whose `applicable?/1` returns
   `false` is reported as `not_applicable`, never `skipped`).
3. `mix tau.audit.health` (nightly cron on `main`) — fails CI on
   `main` if any open finding's probe returns `:ok` (the audit went
   stale — the violation was silently fixed or the probe lost its
   teeth); fails on any waiver past `expires_at`.

**Meta-test** (`test/tau/factory/audit/registry_synthetic_test.exs`):
adds an in-test synthetic finding pointing at a deliberately
violating fixture under `test/support/audit_fixtures/`; asserts a
probe PR touching the fixture surface is failed by
`mix tau.audit.gate`; asserts the same probe returns `:ok` when the
fixture is corrected. Implements acceptance criterion (d) directly.

**Backfill of v1 audit corpus.** `mix tau.audit.import` walks
`docs/problems/` and `docs/problems-archive-v1-modules/`, emits one
draft `priv/audit/findings/F-NNN.yml` per call-site flagged in the
archive (the seven `rescue` sites plus the four other v1-archive
recommendations), each with `status: open` and a stub probe whose
test is `proven_at_sha` = the SHA at which the archive was written
(known from `git log docs/problems-archive-v1-modules/`). The import
is a one-shot bootstrap; subsequent findings are hand-authored. This
implements acceptance criterion (e).

## Tradeoffs

### Strengths

- Closes the loop for every component of the complecting hypothesis
  in *one* mechanism: the probe is the registration, the gate input,
  the remediation evidence, and the staleness monitor.
- Silent-skip impossible by construction (acceptance F of root): a
  probe is either `applied → ok/violation` or `not_applicable`; the
  word `skipped` does not appear in the output schema; `mix
  tau.audit.compile` rejects PRs that introduce a finding lacking a
  probe; the nightly `health` gate catches a probe whose teeth fell
  out.
- Directly catches the four adversarial constructions in the brief:
  (1) a re-introduced port-lifecycle-rescue pattern fires F-007's
  probe on the new PR's diff with no human in the loop; (2) a SPEC
  §4 enumeration inconsistency is registered as a probe over the
  SPEC AST (count of enumerated modes in §4 == count in §6 / D-NNN
  cross-refs) — same substrate, different file extension; (3) an
  ADR supersession (ADR-0021 supersedes ADR-0009) is registered as
  a probe asserting "no module under `lib/tau/` has a `@doc` /
  comment string matching `ADR-0009` without also matching
  `ADR-0021`" until ADR-0009's status is flipped to `superseded`;
  (4) probe staleness — a probe whose
  green-on-main rate drops below 100% halts the loop, surfacing the
  finding for re-proof or status change.
- Generalises the v1 mutation-check property (a gating artifact is
  load-bearing only if its absence demonstrably fails) from
  AC-bearing tests to audit findings — same shape, same gate
  substrate, no new conceptual surface for the coordinator.
- Failure-class #10 is reduced to "is `priv/audit/findings/` ⊇ the
  v1 archive?" — a one-line CI assertion (`mix
  tau.audit.import --check`), not a discipline question.

### Weaknesses

- Probe authoring is non-trivial: every finding now requires an
  Elixir module plus a `proven_at_sha`. A finding authored without
  a probe is rejected, so writing a finding becomes more expensive
  than writing prose. This is intentional but raises the bar for
  contributing audits — the cost may suppress *new* findings,
  re-introducing root-cause #10 in a different shape ("findings
  not written because writing them is hard"). Mitigation: a
  `tau audit scaffold <id>` Mix task that stamps a probe stub from
  templates; metric on the dashboard for "weeks since last audit
  authored" with an escalation threshold.
- The `proven_at_sha` check requires the probe to run against an
  arbitrary historical tree. Probes that depend on dependencies
  (Hex, `mix deps.get` for that SHA) will be slow or break.
  Mitigation: probes are AST-only (no runtime dependency on
  compiled deps) wherever feasible; non-AST probes (e.g. dialyzer-
  based) live in a slower nightly tier.
- Probes can develop the same "screen-scrapes shell output" rot
  that production code can — a probe that pattern-matches on a
  stringified AST may drift silently when Elixir's AST shape
  changes (`Macro.to_string` differences across versions). Partial
  mitigation: the nightly `health` gate's "open probe goes green
  on main" check catches the most common rot mode; the residual
  is silent for a window ≤ 24h.
- This proposal makes the audit registry a hard dependency of
  every PR's CI. A registry bug — e.g. an `applicable?/1` that
  raises — will fail every PR until fixed. Risk shape is identical
  to the existing `mix credo` integration; mitigation is the same
  (registry runs in its own CI job with verbose logs).
- The four adversarial constructions in the brief are mostly
  AST/text patterns. Findings whose probe is genuinely *behavioural*
  (e.g. "this provider's prompt-caching adapter handles the
  `cache_write` key incorrectly under load") need a probe that
  resembles a property test, not a grep. Those probes will be
  expensive and may exceed CI budget. Mitigation: tiered probes
  (`tier: :ast | :unit | :integration | :nightly`), with only
  `:ast` and `:unit` running on every PR.

### Costs

- New code: ~600-900 LOC for `AuditRegistry`, `Probe` behaviour,
  `Diff`, `AST` helper, three Mix tasks, plus the meta-test
  (~150 LOC).
- Backfill: ~11 stub probe modules + 11 findings YAMLs for the v1
  archive (most are AST-pattern probes; budget ~30 LOC per probe).
- CI time: an extra ~10-30s on the PR critical path for `tau.audit.gate`
  (AST-only probes are fast); ~3-5m nightly for `tau.audit.health`.
- Dependency: no new Hex deps (uses `Sourceror` if not already
  present — verify in dependency step; otherwise hand-rolled AST
  traversal via `Code.string_to_quoted/1` is sufficient for the v1
  backfill probes).
- Coordinator brief growth: implementer briefs must mention the
  audit-registry's probe-authoring requirement when work introduces
  a new pattern an existing finding watches for — handled by the
  `applicable?/1` failure being self-explanatory in the gate output.

## Dependencies

- Pre-merge-code-gates sibling (Subproblem 2) must accept the
  audit registry as an input — the gate substrate it designs MUST
  call `Tau.Factory.AuditRegistry.dispatch/2` and treat its
  `violated: [...]` list as merge-blocking. If that sibling chooses
  a wholly bespoke gate API, this proposal's `dispatch/2` shape
  adapts but the substrate must accept *some* registry call.
- Pre-merge-evidence-and-skip-integrity sibling (Subproblem 3)
  must include the audit-registry gate in its silent-skip-
  impossibility audit (gate listed, no `|| true`, no early-exit).
- `Sourceror` (Hex) or equivalent AST library, if hand-rolled
  `Code.string_to_quoted/1` proves insufficient for the more
  complex probe patterns. Decision deferred to first probe that
  needs it; v1 backfill probes are simple enough to avoid it.
- A worktree-isolation contract for `proven_at_sha` probe runs
  (the probe runs against a historical tree via `git worktree
  add <tmp> <sha>`) — already covered by
  `worktree-discipline.md`.

## Confidence

Medium. The mechanism is a direct generalisation of v1's
mutation-check gate (well-understood, already in CI per
`factory-loop.md`), and the failure modes are inherited from
known-good ecosystems (Sobelow, Credo). Confidence is *not* high
because the probe-authoring tax is a real adoption risk and the
"behavioural probe" tier is gestured at rather than designed.
Confidence would rise to high with: (a) a working
`PortLifecycleRescue` probe demonstrated to fail on the v1
archive's named commit and pass on `main`; (b) a measured
`mix tau.audit.gate` PR-critical-path overhead on the current
Tau diff size; (c) a written contract with the pre-merge-code-
gates sibling on the `dispatch/2` shape.

## Prior art / references

- `mix sobelow` — Phoenix security scanner; per-rule modules with
  per-rule pass/fail; same shape as the proposed `Probe`
  behaviour. https://github.com/nccgroup/sobelow
- `mix credo` custom checks — per-check modules registered via
  `.credo.exs`; ours register via `priv/audit/findings/*.yml` for
  finding-status lifecycle.
- v1's `mix tau.gate.mutation` (factory-loop.md §"Gate 5.3") — the
  proof-of-load-bearingness pattern (`proven_at_sha`) is the same
  property generalised from tests to probes.
- GitHub Code Scanning SARIF — considered as an alternative
  *transport* for probe output, rejected here because SARIF
  delivers findings to the GitHub UI but does not enforce the
  authoring-time `proven_at_sha` invariant or the nightly
  staleness check. SARIF emission could be added as a downstream
  reporter without altering this proposal.
- ADR-0019 (`circuit-breaker-is-ets-state-with-lifecycle-anchor`)
  — the registry's GenServer-with-ETS-state shape mirrors this
  in-repo precedent.
- The pattern of "the artifact that defines a check IS the check"
  is core to Clojure spec, Datalog rule registration, and
  property-based testing — Hickey's "decomplecting" applied to
  audit artifacts.
