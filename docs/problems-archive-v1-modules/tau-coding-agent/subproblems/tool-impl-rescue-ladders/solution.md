---
template_version: 1
template_name: solution
parent_problem: problem.md
node_kind: leaf
synthesised_from: [proposals/proposal-1.md, proposals/proposal-2.md, proposals/proposal-4.md]
selection_method: hybrid
revision: 0
---

# Solution: Asymmetric rescue removal — drop session_cwd/1 rescue, tag soft-fail sites distinctly

## Recommendation

Remove the `rescue`/`catch` block from `session_cwd/1` entirely and let the
crash propagate to the supervisor. For `tau_session_status/1` and
`safe_memory_load/1`, retain the rescue but change the return shape: add
`"result_kind": "infrastructure_error"` alongside the existing
`"available": false` field (Proposal 1's tagging, not Proposal 3's new type).
Add a single telemetry call per rescue branch — `[:tau, :tools,
:infrastructure_error]` — to make absorbed errors visible in production
(Proposal 4's observability, scoped only to the retained soft-fail sites).
This hybrid satisfies the acceptance criterion (structurally distinguishable
responses), respects the two valid resolution paths named therein (distinguishable
envelope OR reliance on OTP process model), and allocates each strategy to the
site where it fits the harm profile.

## Selected from

- **Chosen:** hybrid of `proposals/proposal-1.md`, `proposals/proposal-2.md`,
  and `proposals/proposal-4.md`
- **Why chosen:** The three sites are not equivalent in harm profile. `session_cwd/1`
  silently redirects all downstream cwd computation to `File.cwd!/0` on crash —
  this is a correctness error, not degraded-mode behaviour. Proposal 2 is
  correct for this site: remove the rescue, let it crash, let the supervisor
  restart. The other two sites (`tau_session_status/1`, `safe_memory_load/1`)
  return tool-level `available: false` responses; their soft-fail behaviour is
  tolerable for a coding-agent subprocess (the subprocess can observe the reason
  field and decide). Proposal 1's minimal tagging (`"result_kind"`) satisfies
  the acceptance criterion — structurally distinguishable — at the lowest diff
  cost. Proposal 4's telemetry addition is taken only for the retained soft-fail
  sites, making absorbed infrastructure errors observable without adding it to a
  site that no longer absorbs anything.

  Proposal 3 (new `ToolResult` module) is not selected: it solves the same
  problem as Proposal 1 at higher migration cost (new file, new concept) without
  adding decomplecting depth. The type-enforcement benefit is real but
  disproportionate to the problem scope — three private helpers, not an
  extensibility seam. Proposal 4's full strategy is not selected wholesale:
  applying telemetry to `session_cwd/1` before crash propagation is unnecessary
  overhead; the crash itself is the observable event.

## Scoring table

| # | Fit | Decomplecting depth | Migration cost | Risk | Reversibility |
|---|-----|---------------------|---------------|------|---------------|
| 1 | Yes | Surface (tags, rescues stay) | Low (~20 lines) | Low | Easy |
| 2 | Yes | Deep (`session_cwd/1` site) / Partial (others unaddressed) | Low (deletions) | Medium (subprocess observes hard resets) | Easy |
| 3 | Yes | Surface (rescues stay, types added) | Medium (~65 lines + new file) | Low | Easy |
| 4 | Yes | Deep (`session_cwd/1`) + Surface (others) | Medium (~45 lines + otel wiring) | Low | Easy |
| **Hybrid 1+2+4** | **Yes** | **Deep for session_cwd/1; Surface for soft-fail sites** | **Low (~35 lines total)** | **Low** | **Easy** |

## What changes

- `lib/tau/coding_agent/tau_context/tools.ex`:
  - `tau_session_status/1` rescue and catch branches: add `"result_kind" =>
    "infrastructure_error"` to the returned map and emit
    `:telemetry.execute([:tau, :tools, :infrastructure_error], ...)` before
    returning.
  - `safe_memory_load/1` rescue and catch branches: add telemetry emit; the
    return type stays `{:error, binary()}` — caller in `tau_memory_query/2`
    remains unchanged (it already encodes the error as `available: false`).
    Additionally add `"result_kind" => "infrastructure_error"` to the map the
    caller encodes, so the wire format is distinguishable. This requires a small
    change at the `tau_memory_query/2` call site: pattern-match
    `{:error, reason}` and produce `%{"available" => false, "result_kind" =>
    "infrastructure_error", "reason" => reason}` rather than the current bare
    `available: false` map (which did not carry `result_kind`).
  - `session_cwd/1`: delete the `rescue`/`catch` block entirely. The `case`
    match is extended to handle `{:error, :not_found}` → `nil` and
    `{:error, _}` → `nil` explicitly (Proposal 2's pattern). Unexpected returns
    (non-`:ok`/non-`:error` from `snapshot/1`) raise `CaseClauseError` — OTP
    propagates this to the supervisor.
  - Legitimate-absence paths: no change to return shapes.
  - No new modules, no new files.
- `lib/tau/application.ex` (or `lib/tau/otel_reporter.ex`): attach a telemetry
  handler for `[:tau, :tools, :infrastructure_error]` that emits a `Logger.warning`.
  This is the minimal wiring that prevents telemetry from firing into a vacuum.

## What does not change

- The D-035 public contract: every public function still returns `{:ok, String.t()}`.
- The `"available": false` field on legitimate-absence responses — no shape change
  for `:not_found`, unloaded `MemoryLoader`, or `nil` session_id.
- The MCP wire format's existing fields. `"result_kind"` is additive; existing
  subprocess consumers that do not inspect it are unaffected.
- The `tau_session_status/1` behaviour for `{:error, :not_found}` — still returns
  the current soft-absent envelope.
- `safe_memory_load/1`'s behaviour for the `MemoryLoader` availability guard —
  the `Code.ensure_loaded?` path stays as is.
- The three helpers' independence from each other. Each change is self-contained.

## Migration sketch

Land in a single PR touching only `tools.ex` and one of the OTP startup files.
Order: (1) delete `session_cwd/1` rescue — immediately OTP-correct and
independently testable; (2) add `"result_kind"` tagging to the two soft-fail
rescue sites plus the `tau_memory_query/2` call site for `safe_memory_load/1`;
(3) add telemetry emits to the retained rescue branches; (4) attach the
telemetry handler in `application.ex`. No callers outside `tools.ex` change.
The existing `tau_session_status/1` and `tau_memory_query/2` property tests
(if present) should still pass; a new property test asserting that an injected
`snapshot/1` crash propagates out of `session_cwd/1` (rather than returning
`nil`) confirms step 1.

## Open questions

- **Supervision topology:** Proposal 2 flagged that the MCP server process owning
  these helpers must be configured for restart. This is a pre-condition for step 1
  (removing `session_cwd/1` rescue). Verify before landing.
- **`MemoryLoader.load/1` exit semantics:** if `MemoryLoader.load/1` can throw
  bare `:exit` terms, the soft-fail rescue in `safe_memory_load/1` absorbs them
  (currently). Retaining that rescue preserves this absorption. If the goal is
  full OTP compliance, `safe_memory_load/1`'s `catch kind, reason` branch should
  be assessed separately. Not in scope of this solution unless the validator raises it.
- **SPEC-CODING-AGENT amendment:** `"result_kind"` is now a wire-format field that
  subprocess callers can rely on. A §3 amendment to document the semantics is
  warranted; this solution does not block on it (D-035's `{:ok, String.t()}`
  contract is unchanged) but recommends it.
- **Telemetry handler placement:** `application.ex` vs `otel_reporter.ex` is a
  codebase-convention question not resolved here. Either is acceptable; the
  important invariant is that the attachment happens before the tools process
  starts.

## Linked sub-problems / proposals

- `proposals/proposal-1.md` — Tagged `"error_class"` field added to rescue
  branches; rescues retained. Selected for: the `"result_kind"` tagging pattern
  applied to the two soft-fail sites.
- `proposals/proposal-2.md` — Delete all rescues; OTP crash propagation. Selected
  for: the `session_cwd/1` rescue removal.
- `proposals/proposal-3.md` — Introduce `ToolResult` typed constructors. Not
  selected: over-engineered relative to scope; adds a new module for what is
  achievable with additive field changes.
- `proposals/proposal-4.md` — Telemetry-instrumented rescue + `session_cwd/1`
  crash propagation. Selected for: telemetry attachment pattern at retained
  soft-fail sites. Not selected wholesale: telemetry on `session_cwd/1` before
  crash propagation is unnecessary.

## Revision history

- (revision 0 — initial)
