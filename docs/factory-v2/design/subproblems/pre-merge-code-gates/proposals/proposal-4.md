---
template_version: 1
template_name: proposal
proposal_id: 4
parent_problem: ../problem.md
---

# Proposal 4: Five adversarial gates, each constructed backwards from a real v1 failure

## Approach

Build the pre-merge code-gate subsystem as **five independent, bespoke Mix
tasks**, each derived backwards from one concrete v1 failure that the gate
must have caught and didn't. Each gate is the smallest scriptable check that
turns its specific historical failure from "merged" to "blocked", generalises
to a class of analogous failures, and cannot return zero on an empty input
set. The five tasks (`Mix.Tasks.Tau.Gate.CapabilityFidelity`,
`Mix.Tasks.Tau.Gate.NoUnreachableRescue`, `Mix.Tasks.Tau.Gate.BehaviourClosure`,
`Mix.Tasks.Tau.Gate.SpecSymbolExistence`, `Mix.Tasks.Tau.Gate.TelemetryConsumers`)
are wired as five separate required status checks in `.github/workflows/ci.yml`
(no combined "lint" umbrella that hides a skip), each with an inventory file
under `priv/gates/<gate>.inputs.json` whose absence or emptiness fails the
gate rather than passing it. Shared infrastructure is limited to a thin
`Tau.Gate.Inventory` helper that enumerates the input set for each gate and
emits a verdict in a single fixed JSON shape; no other module is shared,
because shared "frameworks" between gates is how v1's CI got a single
`|| true` that silenced the lot.

## Rationale

The complecting hypothesis the leaf names ("the checks are complected with
'the agent's word'") is decomplected by making each check a per-commit
deterministic Mix task whose verdict the gate consumes verbatim. This
proposal extends that: each gate is also decomplected *from the other
gates*. v1's pattern was a unified "lint" job whose internal early-exit
(`ci.yml:88-100`) silenced multiple checks at once; five independent jobs
with five independent required-status-check names make a silent multi-gate
skip structurally impossible. Each gate is justified by an exact PR-merge
that would have failed it — not by an abstract category. The adversarial
construction also forces honesty: a gate whose original failure cannot be
named in one paragraph of code, PR body, and agent self-report is a gate
without a falsifier, and is dropped.

## Sketch

Each gate is constructed from a real v1 failure, generalised, and shown
mechanically. All five share the inventory contract (below) so silent-skip
is structurally impossible.

### Shared inventory contract

```elixir
defmodule Tau.Gate.Inventory do
  @moduledoc """
  Enumerates the input set for a gate. An empty input set returns
  `{:error, :empty_inventory, reason}` so the calling Mix task can exit
  non-zero rather than silently passing on a missing target list.

  Per-gate inventories live in `priv/gates/<gate>.inputs.json` and are
  read by the Mix task at boot. The file MUST exist; CI fails the PR if
  it does not. The file MUST list ≥1 input; an empty list fails the PR.
  """

  @type result :: {:ok, [input :: term]} | {:error, :missing | :empty, String.t()}

  @spec load(atom()) :: result()
  def load(gate_name)
end
```

Verdict JSON every gate emits to stdout (consumed verbatim by CI):

```json
{
  "gate": "capability_fidelity",
  "schema_version": 1,
  "inventory_count": 9,
  "findings": [
    {"file": "lib/tau/providers/deepseek.ex", "line": 51,
     "violation": "prompt_caching: true without cache_regions/2 export"}
  ],
  "verdict": "fail"
}
```

### Failure 1 — `deepseek.ex` declares `prompt_caching: true` with no callback

**Exact v1 failure.** `lib/tau/providers/deepseek.ex:51` returns
`%{... prompt_caching: true, ...}` from `capabilities/0`. `grep` confirms
the module exports `@behaviour Tau.Provider` (line 30) but does NOT export
`cache_regions/2`. The user-facing effect: any call site that branches on
`capabilities().prompt_caching` (see `lib/tau/providers/shared/content_transform.ex:98`,
which already drops `cache_control` blocks when `prompt_caching: false`)
will follow the caching path on DeepSeek, then hit a `function_clause`
error when the policy lookup tries to invoke `cache_regions/2`. Bedrock
(`bedrock.ex:36`) and Gemini (`gemini.ex:30`) carry the same lie.

**Generalisation.** A capability flag in the `capabilities/0` map implies
the existence of a specific behaviour callback. The flag→callback mapping
is small, finite, and lives in `Tau.Provider`:

| capability key | required callback     |
|----------------|-----------------------|
| `prompt_caching: true` | `cache_regions/2` |
| `thinking: true`       | `extended_reasoning/1` (future) |
| `tools: true`          | `format_tools/1` (already mandatory; assert anyway) |

**Mechanism.** `Mix.Tasks.Tau.Gate.CapabilityFidelity` enumerates every
module under `lib/tau/providers/*.ex` whose AST contains
`@behaviour Tau.Provider`, parses `capabilities/0` via `Sourceror.parse_file!`
to extract the literal map, looks up each `true`-valued key in the
flag→callback table, and asserts the module's export list contains the
required callback. Inventory: `priv/gates/capability_fidelity.inputs.json`
lists every adapter file; if the file is absent or empty, exit 2 (CI fails).
If no flag→callback mapping exists, exit 2 (forces the table to be
maintained alongside `Tau.Provider`).

**Silent-skip impossibility.** Exit codes: `0` = inventory ≥1 AND zero
findings; `1` = ≥1 finding; `2` = inventory missing / empty / mapping
table absent. CI treats `2` identically to `1`. There is no `0`-with-no-
inventory path.

### Failure 2 — `Tau.Session.resolve_provider/1` rescues against `String.to_existing_atom/1`

**Exact v1 failure.** `lib/tau/session.ex:488-494`:

```elixir
defp resolve_provider(s) when is_binary(s) do
  try do
    String.to_existing_atom(s)
  rescue
    _ -> Tau.Provider.default()
  end
end
```

`String.to_existing_atom/1` raises `ArgumentError` on an unknown atom —
that IS the reachable failure mode, and the rescue is legitimate. But the
broader pattern in v1 is `try/rescue` wrapping calls that *cannot* fail —
e.g. the `try` at `session.ex:422` (around a `:gen_statem.call` that
already has its own `:timeout` handling), and the seven `rescue` sites
flagged in the prior module audit that moved zero between audits. OTP
non-negotiable #7 forbids `try/rescue` across process boundaries and
`catch :exit` of `:exit` signals.

**Generalisation.** Every `try/rescue` and every `catch :exit` clause is
suspect by default. The gate's job is not to forbid them all (some — like
`String.to_existing_atom/1` — are legitimate) but to force every one to
be **annotated with the specific raising callee and a justification**.
Unannotated rescues are violations. The annotation is parsed; nonsense
text fails.

**Mechanism.** `Mix.Tasks.Tau.Gate.NoUnreachableRescue` uses `Sourceror`
to traverse every `.ex` file under `lib/`. For every `{:try, _, _}` and
every `{:catch, _, [{:exit, _, _}, _]}` AST node, it looks for a sibling
`@rescue_justification` module attribute or a `# rescue: <callee> <reason>`
comment within 3 lines above the `try`. The justification names the
specific raising callee and a one-line reason. The gate cross-checks the
named callee actually exists (via `Code.ensure_loaded?/1` + `function_exported?/3`).
Inventory: every `.ex` file under `lib/tau/`; empty → exit 2.

**Silent-skip impossibility.** Inventory file enumerates the file set;
the file existing with zero entries fails. A PR that adds a rescue and
provides only the comment `# rescue: foo` without a real Elixir callee
fails (the cross-check). A PR that adds a rescue and no comment fails.

### Failure 3 — `@behaviour Tau.Provider` declared without implementing all callbacks

**Exact v1 failure.** `lib/tau/providers/deepseek.ex:30` declares
`@behaviour Tau.Provider`. The behaviour requires `stream/3`, `format_tools/1`,
`merge_usage/2`, etc. The compiler will warn if any are missing, but the
v1 build is run *without* `--warnings-as-errors` on the path that matters
for nightly-style regressions, and `@optional_callbacks` is used liberally
to silence the warning even when the runtime call path expects the
callback. Coupled with capability-flag-implied-callbacks (Failure 1), the
v1 codebase merges adapters whose contract is "stream-only, no tool
support" but whose `capabilities/0` claims `tools: true`.

**Generalisation.** A module that declares `@behaviour M` must export
every non-`@optional_callback` callback of `M`, with the exact arity. The
check is independent of `--warnings-as-errors` (which can be silenced)
and independent of the capability-flag fidelity check (which addresses
a different lie).

**Mechanism.** `Mix.Tasks.Tau.Gate.BehaviourClosure` enumerates every
loaded module via `:application.get_key(:tau, :modules)`, reads
`__info__(:attributes)` for `:behaviour`, fetches each behaviour's
`behaviour_info(:callbacks)` and `behaviour_info(:optional_callbacks)`,
and asserts every required `{fun, arity}` is present in the implementing
module's `__info__(:functions)`. Optional callbacks are reported as
*informational* findings (counted but not failing) when the capability
flag implies them — this links Failure 1 and Failure 3 without complecting
the gates. Inventory: every compiled module in the `:tau` app; empty →
exit 2 (means the app didn't compile).

**Silent-skip impossibility.** The compiled-module set cannot be empty
on a successful build, so an empty input is also a CI-infrastructure
failure (the build broke). Either way exit 2; CI fails.

### Failure 4 — SPEC §4 names `ToolUseStart` and the struct does not exist

**Exact v1 failure.** `docs/spec/SPEC-USER-TURN.md:75` says:

> Provider stream events are assumed to arrive in the order
> `Start → TextStart → TextDelta* → TextEnd → ToolUseStart → ToolUseDelta* → ToolUseEnd → Done`.

`grep -rn ToolUseStart lib/` returns zero hits. `lib/tau/provider/event.ex`
defines `Start`, `Done`, `Text`, etc. but not `ToolUseStart`. The SPEC §4
contract names a symbol that does not exist in code; consuming code
silently never matches the absent pattern, so the streaming bug is masked
rather than surfaced.

**Generalisation.** Every backtick-quoted CamelCase identifier in a
`docs/spec/SPEC-*.md` §4 ("Boundary contracts") that *looks like* a struct
or module name MUST resolve to an actual loaded module or to a literal
quoted in §3 with a "(not yet implemented; tracked by #NNN)" annotation.
A SPEC may not silently promise structs that don't exist.

**Mechanism.** `Mix.Tasks.Tau.Gate.SpecSymbolExistence` reads every
`docs/spec/SPEC-*.md`, locates the `## §4` section by regex, extracts
every backtick-quoted token matching `~r/`([A-Z][A-Za-z0-9_.]+)(?:\(/?\d*\)?)`/`
(module paths and `Mod.fun/arity` references), and looks up each against
the compiled module set (via `Code.ensure_loaded?/1`). Unresolved tokens
fail the gate UNLESS the SPEC §3 prose contains a deferral annotation
matching `~r/#{token}.*\(not yet implemented; tracked by \#\d+\)/`.
Inventory: every `SPEC-*.md` under `docs/spec/`; empty → exit 2.

**Silent-skip impossibility.** A PR that touches a SPEC but leaves the
SPEC file unparseable (no §4 section) fails the gate with exit 2 (input
present, structure invalid). A PR that adds a SPEC mention of a future
struct without the deferral annotation fails with exit 1.

### Failure 5 — `[:tau, :compaction, :exception]` emitted, zero consumers attach

**Exact v1 failure.** `lib/tau/session/compaction.ex` emits
`[:tau, :compaction, :exception]` from four call sites (lines 80, 154, 205,
249). `grep -rn ':telemetry.attach\|telemetry.attach_many'
lib/tau/` returns 5 attach sites total across the whole codebase, and
none of them subscribe to `[:tau, :compaction, :exception]`. The audit
recorded 23 `*.exception` events attached but never emitted, and the
inverse — 79 (64.9% of 122) `:telemetry.execute` sites with zero
non-debug consumer registered. The user-facing effect: a compaction
failure is silently dropped on the floor; no log, no OTel span, no metric.

**Generalisation.** Every event name passed to `:telemetry.execute/3`
must be subscribed to by at least one *production* `:telemetry.attach` or
`:telemetry.attach_many` call. "Production" means: in code under `lib/`,
NOT under `test/` or `test/support/`, NOT inside a function whose
`@moduledoc false` ancestor is a debug-only module.

**Mechanism.** `Mix.Tasks.Tau.Gate.TelemetryConsumers` uses `Sourceror`
to walk every `.ex` under `lib/` and `test/`, collects the literal
event-name list from every `:telemetry.execute(events, ...)` and
`:telemetry.attach(_, events, ...)` / `attach_many` call (events must
be a literal list — non-literal events fail the gate; that prevents a
PR from hiding events behind a runtime expression). It then computes
`emitted_only = emitted_set ∖ attached_set_from_lib` and
`attached_only = attached_set_from_lib ∖ emitted_set`. Both sets must
be empty. Inventory: emitted list + attached list, both ≥1; empty
either → exit 2.

**Silent-skip impossibility.** The lib-attached set being empty means
either OtelReporter is gone (regression) or the inventory is broken;
both fail. Non-literal events fail at AST-parse time. A PR that emits
a new event without adding a consumer in the same diff fails.

### CI wiring

`.github/workflows/ci.yml` gets five named jobs, each a required status
check on `main`:

```yaml
jobs:
  gate-capability-fidelity:
    steps:
      - run: mix tau.gate.capability_fidelity
        # exits 0 / 1 / 2; 0 only on inventory ≥ 1 AND no findings
  gate-no-unreachable-rescue:
    steps:
      - run: mix tau.gate.no_unreachable_rescue
  gate-behaviour-closure:
    steps:
      - run: mix tau.gate.behaviour_closure
  gate-spec-symbol-existence:
    steps:
      - run: mix tau.gate.spec_symbol_existence
  gate-telemetry-consumers:
    steps:
      - run: mix tau.gate.telemetry_consumers
```

No `continue-on-error: true`. No `|| true`. No combined `lint` umbrella.
Five separate required-status-check names recorded in branch protection.

### Sequencing by impact

The gates are sequenced for delivery by the size of the historical
bleed they block:

1. **CapabilityFidelity** — blocks the DeepSeek + Bedrock + Gemini
   adapter lies that currently crash at the cache-policy callsite.
2. **TelemetryConsumers** — addresses 64.9% of telemetry sites + 23
   never-emitted exception attachments; highest "drift surface area."
3. **BehaviourClosure** — currently masked by `--warnings-as-errors`
   silencing; resurfaces it mechanically.
4. **SpecSymbolExistence** — blocks the SPEC↔code drift class
   exemplified by `ToolUseStart`.
5. **NoUnreachableRescue** — slowest to land (every legitimate
   rescue needs an annotation pass), so last.

## Tradeoffs

### Strengths

- **Each gate has a named falsifier.** Drop any gate, point to the
  specific historical merge it would no longer catch. That is the
  Toulmin-warrant test the v1 process was supposed to apply and didn't.
- **Five independent required status checks** make a silent multi-gate
  skip structurally impossible — addresses leaf AC (c) and root §C.
- **Inventory contract makes empty-set silent-pass impossible.** Every
  gate exits 2 on a missing or empty inventory file; CI treats 2 as
  failure. Directly answers leaf AC (b).
- **Generalisations are tight to the failure.** Each gate generalises
  *only* to the class its constructed failure exemplifies (capability
  flags → behaviour callbacks; one rescue → all rescues; one SPEC
  symbol → all §4 backtick-tokens). No gate is a "platform" looking
  for a use case.
- **Pure bespoke choice is justified per gate.** CapabilityFidelity
  has no off-the-shelf equivalent (the flag→callback table is
  Tau-specific). NoUnreachableRescue's annotation discipline cannot
  be expressed in `credo --strict` without a custom check, and at that
  point a Mix task is simpler. BehaviourClosure could use Dialyzer's
  `@callback` warnings, but Dialyzer's slow PLT generation and
  configurability (warnings can be silenced) make a bespoke compiled-
  module check more deterministic. SpecSymbolExistence and
  TelemetryConsumers have no analogues anywhere.
- **Linked but not complected.** BehaviourClosure reports optional-
  callback gaps the capability flag implies as *informational*
  findings, surfacing the link to CapabilityFidelity without merging
  the two gates' verdict logic.

### Weaknesses

- **Five gates is N+1 maintenance.** Every new failure class is a new
  Mix task and a new CI job. The leaf problem names four classes; this
  proposal commits to five gates (one extra: SPEC symbol existence is
  arguably code↔spec drift, which the leaf attributes to
  intent-capture-and-ac-binding or post-merge-cross-artifact-coherence
  — see Dependencies for the boundary question).
- **NoUnreachableRescue's annotation discipline burdens every legitimate
  rescue site.** The migration cost is one annotated rescue per existing
  site (~7 sites from the audit + however many surface). Failure to
  annotate during the migration PR blocks every subsequent PR until
  done.
- **Sourceror-based AST traversal is slower than `grep`.** On a full
  repo scan this is seconds, not minutes; on CI it's negligible. But
  the proposal commits to AST correctness, so all checks are at least
  one `Sourceror.parse_file!` deep — no shortcuts.
- **TelemetryConsumers' "production handler" definition is heuristic.**
  Distinguishing test/support attaches from production attaches via
  path is fragile if production code ever lives under `test/support/`
  (it shouldn't, but the heuristic doesn't enforce that). Mitigation:
  add a `Tau.Gate.TelemetryConsumers.ProductionPath` allowlist that
  the gate's own inventory rejects if it grows beyond the natural set.
- **SpecSymbolExistence can produce false positives** when a SPEC §4
  cites a future symbol with imperfect deferral annotation. The
  proposal demands the annotation be exact; SPEC authors will need a
  short template. False-positive cost: one extra PR to amend the SPEC.
- **No mutation testing in this proposal.** The leaf out-of-scope
  excludes per-AC mutation, but a check like "does removing a rescue
  break any test" would catch a different class of dead-rescue. Not
  in scope here; sibling intent-capture-and-ac-binding may pick it up
  via the gating-test path set.

### Costs

- **Migration:** 5 Mix tasks (~150 lines each = ~750 lines of gate
  code) + 1 `Tau.Gate.Inventory` helper (~80 lines) + 5 inventory
  JSON files. Initial annotation pass for NoUnreachableRescue:
  ~7-12 rescue sites × 1 annotation each. Initial SPEC §4 audit for
  SpecSymbolExistence: ~10 SPECs × ~5 minutes each.
- **CI runtime:** ~30s per gate worst case (Sourceror parse of
  ~200 .ex files); 5 parallel jobs → adds ~30s to PR check time.
- **Test surface:** Each Mix task needs property tests over
  synthetic ASTs + at least one example test pinned to a known
  good/bad file under `test/support/gates/`. ~50 test cases total.
- **Dependency impact:** `Sourceror ~> 1.0` added to mix.exs (small,
  pure-Elixir, no native deps). No other new deps.
- **Knowledge:** every PR author must know the inventory JSON pattern
  and the annotation comment grammar for rescues. One README under
  `priv/gates/README.md` (≤50 lines) suffices.

## Dependencies

- The `flag→callback` mapping table must live in `Tau.Provider` (or a
  sibling `Tau.Provider.CapabilityTable`). Adding a new flag without
  adding to the table fails CapabilityFidelity's exit-2 inventory
  branch, which forces the table to stay current.
- The boundary between this leaf and **intent-capture-and-ac-binding**
  on the SPEC-symbol question: the leaf problem (this one) covers
  AST/contract/capability/telemetry on the production diff. SPEC
  symbol existence is a SPEC↔code drift check that runs on every PR
  that touches *either* code or SPEC. This proposal claims it for
  pre-merge code gates because the falsifier (SPEC §4 names a struct
  the code lacks) is a code-side liability when a PR touches the
  code without adding the struct. If the design tree later assigns it
  to post-merge-cross-artifact-coherence, drop this gate from PR-5
  scope (the other four stand alone).
- **pre-merge-evidence-and-skip-integrity** sibling: this proposal
  assumes that sibling will own (a) branch-protection wiring to mark
  these five jobs as required status checks, (b) the ban on
  `continue-on-error: true` / `|| true` in `ci.yml`, and (c) the
  pre-merge "all required checks green" assertion. Without that
  sibling's work, the five gates run but can still be merged-around.
- `Sourceror ~> 1.0` (Hex package, well-established, used by ElixirLS).

## Confidence

**High** for CapabilityFidelity, TelemetryConsumers, and BehaviourClosure
— prior art exists (Dialyzer for callbacks, OpenTelemetry SDK introspection
for handlers, multiple Elixir static-analysis tools for capability/contract
checks). Each is constructed from a verified-by-grep v1 failure.

**Medium** for NoUnreachableRescue (the annotation grammar is new and
will need a short feedback loop with the team) and SpecSymbolExistence
(the §4 regex must handle edge cases like generics and function refs).
Both gates are scoped tight enough that the prototype is < 200 lines.

What would raise confidence: prototype each Mix task against the current
repo, observe how many findings each surfaces (the count itself validates
the gate is calibrated correctly), and post the inventory JSONs to a
small sample of PRs before flipping the branch-protection switch.

## Prior art / references

- `mix dialyzer` `@callback` warnings — prior art for behaviour-closure
  checking; rejected as load-bearing because (a) PLT generation is slow
  enough that v1 teams routinely run without it, (b) warnings can be
  suppressed via `@dialyzer` attributes, and (c) Dialyzer is silent on
  the capability-flag-implies-callback link.
- `mix credo --strict` custom checks — prior art for AST-traversal lint
  rules; rejected as the *substrate* because Credo's check API encodes
  severity in a way that lets a project run with all checks set to
  `:warning` (silenceable). A bespoke Mix task that exits non-zero is
  unambiguous.
- OpenTelemetry SDK `OpenTelemetry.handlers/0` introspection — direct
  prior art for TelemetryConsumers' "registered handler" check.
- `Sourceror` (https://hex.pm/packages/sourceror) — used by ElixirLS,
  Refactorex, and the Elixir formatter; the standard AST library for
  this kind of source-level analysis.
- v1 audit `docs/problems/` — the source of truth for the historical
  failure constructions in this proposal. Every Failure-N in §Sketch
  cites a specific file:line or count from the audit.
