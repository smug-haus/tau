---
template_version: 1
template_name: solution
parent_problem: ../../problem.md
node_kind: leaf
synthesised_from: [proposals/proposal-1.md, proposals/proposal-2.md]
selection_method: hybrid
revision: 0
---

# Solution: In-place iolist cap guards + shared `Tau.IO.Port` utility

## Recommendation

Fix all three sites in-place using iolist accumulation with a running byte
counter and an in-loop cap guard, eliminating both the OOM risk and the O(n²)
concatenation in a single move. Extract exactly one shared artefact:
`Tau.IO.Port.close_if_open/1` as a public utility function in a minimal
`lib/tau/io/port.ex` module. The three `collect_*` functions remain private to
their owning modules; no new namespace layer is imposed on callers. The MCP
stdio `{:noeol, partial}` path gets an inline byte-cap guard in `recv/2`.

## Selected from

- **Chosen:** hybrid of `proposals/proposal-2.md` (in-place fixes + iolist
  accumulation + local `close_if_open/1`) and `proposals/proposal-1.md`
  (shared `close_if_open/1` extraction).
- **Why chosen:** Proposal 2 dominates on fit, decomplecting depth (the cap is
  co-located with the accumulation expression, not separated by a function
  boundary), migration cost, and reversibility. Its sole weakness is the
  three-way duplication of `close_if_open/1` — a two-line private helper
  repeated in three modules. Proposal 1's only clearly superior element is the
  extraction of that helper into a named, testable, single-source-of-truth
  function. A minimal hybrid takes that one element from Proposal 1 and
  applies it to Proposal 2's in-place structure. This is a coherent composition:
  Proposal 2's accumulation fix is not altered; Proposal 1's helper extraction
  is applied unchanged to the liveness-guard duplication. The result is strictly
  better than either alone at negligible additional cost (one 4-line utility
  module). Proposals 3 and 4 are rejected: Proposal 3 adds OTP supervision
  machinery (DynamicSupervisor, GenServer lifecycle, ref-based reply) to what is
  essentially a bounded buffer — the isolation gain does not justify the
  complexity, and the caller-in-GenServer-context problem for `hooks/shell.ex`
  is unresolved. Proposal 4 introduces a four-module behaviour hierarchy where
  the behaviour's contract is immediately violated by `LineFramed`'s need to
  thread `state.partial` — a pre-existing accumulator not expressible in the
  `collect/3` callback signature — making the behaviour a nominal contract
  rather than an enforced one.

## Scoring table

| # | Fit | Decomplecting depth | Migration cost | Risk | Reversibility |
|---|-----|---------------------|----------------|------|---------------|
| 1 | Yes | Substantial | Low | Low | Easy |
| 2 | Yes | Deep | Low | Low | Easy |
| 3 | Yes | Substantial | High | Medium | Hard |
| 4 | Partially | Substantial | High | Medium | Hard |

Proposal 2 scores deepest on decomplecting: the cap guard lives in the same
clause as the accumulation expression, making the loop invariant visible and
local. Proposal 4 scores Partially on fit because the `LineFramed` behaviour
callback cannot honestly represent the `state.partial` continuation — the
proposer acknowledges this requires "an optional `initial_partial` parameter
... diverging from the behaviour callback signature."

## What changes

- **`lib/tau/io/port.ex`** (new): defines `Tau.IO.Port.close_if_open/1` — the
  `Port.info(port) != nil` liveness guard as a single exported function.
- **`lib/tau/tools/operations/local.ex`**: `collect_port/3` → replaces
  `acc <> data` with `[data | acc]` prepend, adds a running `acc_bytes`
  counter, adds the in-loop cap guard that calls `Tau.IO.Port.close_if_open/1`
  and exits `{:ok, ..., :cap_reached}` when `acc_bytes >= @max_bytes`. The
  `try/catch` around `Port.close/1` at line 157 is replaced with
  `Tau.IO.Port.close_if_open(port)`. Terminal clause uses `IO.iodata_to_binary/1`.
  The `@max_bytes` constant is made explicit at this module level (currently
  implied via `Bash.truncate/3`).
- **`lib/tau/hooks/shell.ex`**: `collect/3` → same iolist + running counter +
  in-loop cap guard pattern. Adds `@max_output_bytes 32_768` (matching Bash's
  existing policy). The `try/catch` around `Port.close/1` at line 151 is
  replaced with `Tau.IO.Port.close_if_open(port)`.
- **`lib/tau/mcp/transport/stdio.ex`**: `recv/2` `{:noeol, partial}` branch →
  adds `if byte_size(new_partial) >= @max_partial_bytes` guard returning
  `{:error, {:partial_overflow, byte_size(new_partial)}}`. Adds
  `@max_partial_bytes 65_536`. The `try/catch` around `Port.close/1` at
  line 82 is replaced with `Tau.IO.Port.close_if_open(port)`.

## What does not change

- The `Tau.MCP.Transport` behaviour contract (`recv/2` and `close/1`
  signatures) — callers see no API change.
- `lib/tau/tools/builtin/bash.ex`'s `truncate/3` — it still runs after
  `collect_port/3` returns; the in-loop cap now ensures `truncate/3` always
  receives a buffer that is already within bounds, making `truncate/3` a
  no-op in the cap-reached path. No callers of `truncate/3` change.
- `collect_port/3`, `collect/3`, and `recv/2` remain private to their
  owning modules; no new dependency edge is introduced at the tool level.
- The supervision tree — no new processes, supervisors, or application children.
- All existing tests for the truncation behaviour in `bash_test.exs`; the
  earlier truncation point (mid-loop vs post-loop) must be verified, but the
  existing assertions on bounded output remain valid.

## Migration sketch

1. Add `lib/tau/io/port.ex` with `close_if_open/1`. No callers yet.
2. Fix `local.ex`: promote `@max_bytes` to a module attribute, rewrite
   `collect_port/3` with iolist acc + running counter + cap guard, replace
   `try/catch` with `Tau.IO.Port.close_if_open/1`. Run existing Bash tests.
3. Fix `hooks/shell.ex`: add `@max_output_bytes`, rewrite `collect/3`,
   replace `try/catch`. Run hook tests.
4. Fix `mcp/transport/stdio.ex`: add `@max_partial_bytes`, add noeol guard,
   replace `try/catch`. Run MCP transport tests.
5. Add a new test (`test/tau/io/port_test.exs` or inline in the Bash tool
   tests) that pipes a stream exceeding the cap and asserts bounded output
   and no crash — satisfying the acceptance criterion's verifiability clause.

Steps 2–4 are independent and may land in a single commit or three sequential
commits; they share no code until step 1 is in.

## Open questions

- **`@max_bytes` threading in `local.ex`**: the constant currently lives in
  `bash.ex` (line 9–10 per the problem context). The solution requires it to
  be explicit in `local.ex`. If `bash.ex` imports or aliases it from `local.ex`,
  the direction of that dependency must be confirmed before implementation.
- **`hooks/shell.ex` cap value**: `32_768` (matching Bash) is a reasonable
  default, but the hook runner may have a different policy intention. The
  implementer should confirm with the hook-runner opts interface before hardcoding.
- **Existing `truncate/3` test assertions**: some tests may assert on exact
  truncation byte counts that differ between mid-loop (iolist-chunk-boundary)
  and post-loop (exact byte slice) truncation. These must be audited in step 2.
- **UTF-8 boundary on `binary_part/0, max_bytes`**: truncating at an exact
  byte count may split a multi-byte codepoint. The problem acceptance criterion
  does not require clean codepoint boundaries, but this should be flagged in the
  implementation PR.

## Linked sub-problems / proposals

- `proposals/proposal-1.md` — `Tau.IO.BoundedCollector` shared extraction;
  `close_if_open` element taken for the hybrid.
- `proposals/proposal-2.md` — in-place iolist cap guards; dominant approach
  for accumulation and in-loop cap enforcement.
- `proposals/proposal-3.md` — `Tau.IO.Collector` GenServer; rejected:
  over-engineered for the problem, unresolved caller-in-GenServer-context issue.
- `proposals/proposal-4.md` — `Tau.IO.Collector` behaviour hierarchy; rejected:
  behaviour contract cannot honestly represent `LineFramed`'s `state.partial`
  threading, making it a nominal rather than enforced contract.

## Revision history

- (revision 0 — initial)
