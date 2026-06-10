---
template_version: 1
template_name: validation
parent_solution: solution.md
parent_problem: problem.md
toulmin_complete: true
falsification_attempted: true
falsification_outcome: partially_falsified — claim/3
revision_triggered: none
---

# Validation: In-place iolist cap guards + shared `Tau.IO.Port` utility

## Overview

The solution makes seven distinct checkable propositions: (1) a new
`Tau.IO.Port.close_if_open/1` utility replaces `try/catch` at all three
sites; (2) `local.ex`'s `collect_port/3` is rewritten with iolist
accumulation + a running byte counter + an in-loop cap; (3)
`hooks/shell.ex`'s `collect/3` receives the same treatment with a newly
introduced `@max_output_bytes 32_768`; (4) `mcp/transport/stdio.ex`'s
`recv/2` gains a `@max_partial_bytes 65_536` guard on the
`{:noeol, partial}` branch; (5) the `Tau.MCP.Transport` behaviour
contract is preserved; (6) `bash.ex`'s `truncate/3` is preserved as a
no-op-in-cap-reached safety net; (7) no new supervision-tree nodes are
introduced. Each claim is validated with the Toulmin six-tuple and an
explicit falsification strategy drawn from the validate.md catalog.

The dominant outcome is **withstood**, with one **partial falsification**
on claim 3 (the `32_768` byte cap for the hook collector is asserted
without evidence that hook outputs are bounded by the same policy that
governs the `Bash` tool — the solution itself flags this as an open
question and the qualifier is narrowed accordingly).

## Toulmin per claim

The MITRE empirical study on Toulmin formalism found that "participants
found it difficult to generate Toulmin structures, and their structures
varied greatly even though they started with the same content"
(https://www.mitre.org/news-insights/publication/empirical-evaluation-structured-argumentation-using-toulmin-argument).
This template enforces all six components explicitly with prompts to
counter that variance.

### Claim 1: `Tau.IO.Port.close_if_open/1` replaces `try/catch` at all three sites

- **Claim (C):** A new module `lib/tau/io/port.ex` defining a single
  exported function `Tau.IO.Port.close_if_open/1` (a `Port.info(port) !=
  nil` liveness guard + conditional `Port.close/1`) replaces the
  `try/catch` blocks at `local.ex:157`, `hooks/shell.ex:151`, and
  `stdio.ex:82`, eliminating the use of `try/catch` across a process
  boundary at all three port-collector sites.
- **Grounds (G):** The three try/catch blocks exist verbatim today:
  `lib/tau/tools/operations/local.ex:157-161` (try/catch around
  `Port.close(port)`); `lib/tau/hooks/shell.ex:151-155` (identical
  pattern); `lib/tau/mcp/transport/stdio.ex:82-86` (identical
  pattern). The `Port.info(port) != nil` idiom already has prior use
  in this codebase at `lib/tau/coding_agents/claude_code.ex:406`,
  confirming the liveness-check pattern is accepted in-tree.
- **Warrant (W):** Tau OTP non-negotiable #7 ("Let it crash;
  supervise; restart. MUST NOT `try/rescue` across process
  boundaries.") prohibits exactly the `try/catch` pattern these
  three sites use to swallow `Port.close/1` exits. A single named,
  documented utility centralises the liveness guard so future
  collectors inherit the correct idiom rather than re-introducing the
  banned pattern.
- **Qualifier (Q):** Holds for the three named sites and any future
  caller that uses `Tau.IO.Port.close_if_open/1`. Does not apply to
  callers who continue using `Port.close/1` directly outside this
  utility.
- **Rebuttal (R):** If `Port.info(port)` itself can raise on a
  garbage-collected port reference, the utility merely moves the
  failure mode rather than eliminating it. Per Erlang docs,
  `Port.info/1` returns `nil` for non-existent ports rather than
  raising, so the rebuttal does not bite — but this is a
  documentation-supported invariant, not a typespec-enforced one.
- **Backing (B):** `.claude/rules/otp-non-negotiables.md` (Invariant
  #7, "MUST NOT `try/rescue` across process boundaries"); Erlang
  `Port` module documentation
  (https://www.erlang.org/doc/man/erlang.html#port_info-1) for
  `port_info/1` returning `undefined` (Elixir `nil`) for invalid
  ports.

#### Falsification attempt for claim 1

- **Strategy:** dependency check + counter-example construction over
  the documented `Port.info/1` failure modes.
- **Attempt:** (i) Confirmed the three cited try/catch blocks exist at
  exactly the line numbers stated (local.ex:157-161, shell.ex:151-155,
  stdio.ex:82-86); (ii) confirmed the `Port.info` idiom is already
  used at `coding_agents/claude_code.ex:406`, ruling out
  "novel-pattern" objections; (iii) enumerated the racy edge case
  where the port could die between `Port.info(port)` and `Port.close(port)`
  — in that race `Port.close/1` on a dead port returns `true` per
  Erlang docs rather than raising, so a bare `Port.close/1` after the
  liveness check does NOT need its own guard; (iv) checked that no
  caller depends on the `try/catch`'s swallowing of any exception
  *other* than the port-already-closed `:badarg` — `local.ex` only
  catches inside the `:timeout` after-clause, and the only documented
  reason `Port.close/1` raises is `:badarg` on an invalid port, so the
  catch is over-broad today and the helper is strictly safer.
- **Outcome:** withstood — the helper achieves the claimed
  decomplecting + idiomatic-cleanup goal at the three sites without
  introducing a new failure mode.
- **Action:** none.

### Claim 2: `local.ex`'s `collect_port/3` is rewritten with iolist accumulation + running byte counter + in-loop cap

- **Claim (C):** `collect_port/3` in `lib/tau/tools/operations/local.ex`
  replaces `acc <> data` with `[data | acc]` prepend, adds a running
  `acc_bytes` counter, adds an in-loop cap guard that calls
  `Tau.IO.Port.close_if_open/1` and exits `{:ok, ..., :cap_reached}`
  when `acc_bytes >= @max_bytes`, with the terminal clause emitting
  `IO.iodata_to_binary/1`. `@max_bytes` is promoted to a module-level
  attribute in `local.ex`.
- **Grounds (G):** Current `collect_port/3` is exactly the pattern the
  claim repudiates: `lib/tau/tools/operations/local.ex:148-165` shows
  the `{^port, {:data, data}} -> collect_port(port, acc <> data,
  deadline)` clause, with the truncation cap only applied later via
  `Tau.Tools.Builtin.Bash.truncate/3` at `bash.ex:104-129`. `@max_bytes
  = 32 * 1024` is defined at `bash.ex:35`, NOT in `local.ex` — so
  promoting it requires either duplicating the value or moving it.
  The `[h | t]` prepend + `IO.iodata_to_binary/1` pattern is
  Elixir-idiomatic for bounded accumulation (documented in
  `IO.iodata_to_binary/1` hexdocs).
- **Warrant (W):** O(n²) binary concatenation under unbounded
  accumulation is a documented memory-pressure path on the BEAM
  (refcounted binary copy per concat). Replacing `<>` with iolist
  prepend yields O(1) amortised growth and O(n) finalisation;
  combining this with an in-loop cap guard makes the memory bound a
  loop invariant rather than a post-loop afterthought, which is
  precisely the decomplecting move the problem statement asks for.
- **Qualifier (Q):** Holds for the `collect_port/3` rewrite in
  `local.ex`. Assumes `@max_bytes` migrates from `bash.ex:35` to
  `local.ex` (the solution's own open question #1 acknowledges this).
- **Rebuttal (R):** `IO.iodata_length/1` per chunk is O(length of the
  iolist) and so cumulative work to compute the running length is
  O(n²) in chunk count — but a running integer counter (`acc_bytes +
  byte_size(data)`) sidesteps this; the solution explicitly chooses
  the counter form. With the counter the rebuttal does not bite. A
  separate rebuttal: terminal `IO.iodata_to_binary/1` still allocates
  one large binary, so peak memory is O(@max_bytes), not lower — but
  the cap is the point, and this is unchanged from the existing
  truncation contract.
- **Backing (B):** Elixir `IO` module docs on "Building strings
  efficiently" (iolist accumulation pattern,
  https://hexdocs.pm/elixir/IO.html#iodata_to_binary/1); the flat
  audit at `.code_audit/archive/v1-flat/03-tools-hooks-mcp.md` (cited
  in `problem.md` Context) calls the existing pattern "a misbehaving
  command will OOM the BEAM before the truncation logic ever sees the
  buffer."

#### Falsification attempt for claim 2

- **Strategy:** edge-case enumeration over the failure modes the cap
  invariant must rule out, plus a type-level check on the cap-reached
  terminal clause.
- **Attempt:** (i) Enumerated: command that writes one byte at a time
  (cap fires after `@max_bytes` iterations — bounded, OK); command
  that writes >@max_bytes in a single chunk (cap fires on first
  receive — bounded, OK; binary part may slice mid-UTF-8 codepoint,
  flagged in open question #4 and inherited here); command that
  writes nothing and exits cleanly (terminal `:exit_status` clause
  emits `IO.iodata_to_binary([])` = `""` — OK); command that exits
  before any data (same — OK); timeout fires mid-accumulation (after
  clause closes port, returns `{:error, :timeout}` — unchanged from
  today, OK); (ii) Type-level: `IO.iodata_to_binary/1` accepts any
  iolist including `[data | acc]` recursive prepends; result is
  always `binary`; (iii) Confirmed `bash.ex`'s downstream
  `truncate/3` accepts any binary input and is unaffected by which
  side enforces the cap.
- **Outcome:** withstood — the rewrite achieves the claimed bound
  with no enumerated edge case falsifying it.
- **Action:** none. The UTF-8 boundary concern (open question #4) is
  acknowledged and is not a falsification of the cap claim itself.

### Claim 3: `hooks/shell.ex`'s `collect/3` adopts the same pattern with `@max_output_bytes 32_768`

- **Claim (C):** `collect/3` in `lib/tau/hooks/shell.ex` is rewritten
  with iolist accumulation + running counter + in-loop cap guard;
  `@max_output_bytes 32_768` is added as a module attribute "matching
  Bash's existing policy"; the `try/catch` around `Port.close/1` at
  line 151 is replaced with `Tau.IO.Port.close_if_open/1`.
- **Grounds (G):** Current `collect/3` at
  `lib/tau/hooks/shell.ex:145-159` matches the claimed defect
  pattern exactly: `acc <> d` accumulation with no cap, try/catch
  around `Port.close/1` in the after-clause. Bash's `@max_bytes = 32
  * 1024` (`bash.ex:35`) is 32_768, so the proposed value matches by
  arithmetic. However, `hooks/shell.ex` has NO existing cap and NO
  documented policy stating that hook output should share the Bash
  tool's tail-truncation envelope — the only contract documented in
  the moduledoc (`shell.ex:13-26`) discusses exit codes and JSON
  response keys (`continue`, `updatedInput`), not output size.
- **Warrant (W):** The decomplecting argument (Warrant for Claim 2)
  carries unchanged for the iolist + cap mechanism. For the *cap
  value* specifically, the warrant is policy consistency: in absence
  of an explicit hook-side policy, defaulting to the established
  Bash policy is a reasonable conservative choice — though it is a
  policy decision, not a derivation from any existing invariant.
- **Qualifier (Q):** The mechanism (iolist + cap guard + helper)
  holds unconditionally. The *value* `32_768` is qualified: it holds
  IF and only if the hook runner has no countervailing policy. The
  solution itself documents this in open question #2 ("the hook
  runner may have a different policy intention. The implementer
  should confirm with the hook-runner opts interface before
  hardcoding.").
- **Rebuttal (R):** A legitimate hook (e.g., a security-audit hook
  that emits a multi-MB JSON blob describing a tool invocation) may
  require headroom well above 32 KiB. Setting the cap to Bash's
  value silently truncates such hooks' stdout, and since hook output
  is parsed as JSON (`shell.ex:124`), mid-buffer truncation will
  cause `Jason.decode/1` to fail and the hook falls through to
  `:cont` (the `_ -> :cont` clause), masking the truncation
  altogether.
- **Backing (B):** Same as Claim 2 for the mechanism. For the cap
  value: there is NO backing for `32_768` as a hook policy — the
  solution acknowledges this is implementer-discretion territory.

#### Falsification attempt for claim 3

- **Strategy:** prior-art counter-case + edge-case enumeration on the
  cap value.
- **Attempt:** (i) Searched the codebase for any existing hook output
  policy or test that asserts hook output size — none found; (ii)
  Enumerated the failure mode where a hook emits more than 32 KiB of
  JSON: mid-buffer cap → truncated binary → `Jason.decode/1` fails →
  `_ -> :cont` clause silently treats the hook as continuing,
  losing the `continue: false` signal a hook might have intended;
  (iii) Confirmed the solution's own open question #2 explicitly
  flags this as unverified.
- **Outcome:** partially falsified — the *mechanism* claim
  (iolist + cap + helper) survives unchanged. The *value* claim
  ("matching Bash's existing policy" as a defensible default) does
  not survive: there is no Bash *hook* policy, only a Bash *tool*
  policy, and the failure mode where a >32 KiB hook output silently
  degrades to `:cont` is a real bug pattern. The narrowed
  qualifier: "the mechanism is correct; the value `32_768` is an
  implementer-decision the solution defers and the implementer
  MUST confirm against the hook-runner opts interface before
  hardcoding."
- **Action:** narrow qualifier in place; no solution revision
  required because the solution already documents the open question.
  The implementer must treat open question #2 as a blocker on the
  cap value (not on the mechanism) before merging the hook-side
  edit. Recorded under Outstanding doubts for the parent validator.

### Claim 4: `mcp/transport/stdio.ex`'s `recv/2` gains a `@max_partial_bytes 65_536` guard on the `{:noeol, partial}` branch

- **Claim (C):** The `{:noeol, partial}` branch in
  `lib/tau/mcp/transport/stdio.ex:70-71` adds an
  `if byte_size(new_partial) >= @max_partial_bytes` guard returning
  `{:error, {:partial_overflow, byte_size(new_partial)}}`;
  `@max_partial_bytes 65_536` is added as a module attribute; the
  `try/catch` around `Port.close/1` at line 82 is replaced with
  `Tau.IO.Port.close_if_open/1`.
- **Grounds (G):** Current `recv/2` at
  `lib/tau/mcp/transport/stdio.ex:64-78` shows the `{:noeol, partial}`
  branch recurses with `state.partial <> partial`, with no cap on
  cumulative partial length. The port already enforces a 4 MiB
  per-`{:line, _}` framing cap via `@max_line` at line 22, but a
  single MCP message that *never* terminates with a newline can grow
  `state.partial` up to that 4 MiB framing cap unbounded across many
  `{:noeol, _}` deliveries — and on a fast producer the BEAM could
  buffer the inbound chunks ahead of the receive, so the effective
  bound is "as much as the kernel pipe + Port queue holds," not 4
  MiB.
- **Warrant (W):** The Port-framing cap (`@max_line`) bounds a single
  Erlang-side line frame, NOT the application-side `state.partial`
  accumulator stitching multiple `:noeol` deliveries. The
  application-side guard is the only thing standing between a
  pathological/no-newline producer and unbounded `state.partial`
  growth. The decomplecting move (cap inside the loop body rather
  than at termination) is the same as Claims 2 and 3.
- **Qualifier (Q):** Holds for the `recv/2` `{:noeol, _}` branch.
  Does not change behaviour for well-formed MCP traffic where lines
  arrive within `@max_line` and terminate with `\n`.
- **Rebuttal (R):** `65_536` (64 KiB) is below the framing cap of 4
  MiB — so the application guard fires before the framing cap. If a
  legitimate MCP message exceeds 64 KiB without an internal newline
  (e.g., a single JSON-RPC reply with a large embedded payload), the
  guard returns an error and the transport will refuse work that
  would have succeeded under the prior code. The solution does not
  argue why 64 KiB is the right value over, say, 1 MiB; this is an
  implementer decision left implicit.
- **Backing (B):** MCP spec specifies newline-delimited JSON-RPC
  (https://spec.modelcontextprotocol.io/specification/basic/transports/#stdio);
  the moduledoc at `stdio.ex:1-18` says "MCP framing is
  newline-delimited JSON-RPC." Any single JSON-RPC message is
  expected to fit within one line; the `@max_partial_bytes` value
  is bounded above by `@max_line = 4 MiB` and below by "smallest
  reasonable single-message size." 64 KiB sits in that range.

#### Falsification attempt for claim 4

- **Strategy:** dependency check + counter-example construction on
  legitimate-MCP-message sizes.
- **Attempt:** (i) Confirmed `@max_line 4 * 1024 * 1024` already
  bounds the Port-framing layer; (ii) Confirmed `state.partial`
  *concatenation* has no cap today and a pathological producer can
  starve the recv loop arbitrarily; (iii) Counter-example: a
  legitimate MCP message containing a large `tools/list` response
  with many tools and verbose JSON-schema descriptions might exceed
  64 KiB on a single line — none observed in the repo's MCP
  fixtures, but not implausible; (iv) Conclusion: the guard
  correctly bounds the pathological case; the value `65_536` is
  defensible but not derived from any measured ceiling on
  legitimate MCP message sizes.
- **Outcome:** withstood — the *guard* mechanism is correct; the
  *value* is implementer-discretion (parallel to Claim 3) but not
  falsified because the chosen value lives in a defensible range
  bounded above by the existing `@max_line`.
- **Action:** flag the value choice for implementer review (parallel
  to Claim 3); no qualifier change required because the qualifier
  already excludes "well-formed MCP traffic where lines arrive
  within `@max_line`."

### Claim 5: The `Tau.MCP.Transport` behaviour contract is preserved

- **Claim (C):** "The `Tau.MCP.Transport` behaviour contract
  (`recv/2` and `close/1` signatures) — callers see no API change."
- **Grounds (G):** The proposed changes touch the *body* of `recv/2`
  (`stdio.ex:65-78`) and `close/1` (`stdio.ex:80-89`) but not their
  signatures. The new return shape on the cap-reached path is
  `{:error, {:partial_overflow, byte_size(new_partial)}}` which is
  a member of the documented `{:error, term()}` return shape of the
  `Tau.MCP.Transport.recv/2` callback.
- **Warrant (W):** A behaviour contract change requires either a
  callback-signature change or a documented return-shape narrowing
  that prior callers depended on. Neither applies here: the return
  shape stays within `{:ok, _, _}` | `{:error, _}`.
- **Qualifier (Q):** Holds as long as callers pattern-match on
  `{:error, _}` generically rather than enumerating specific error
  atoms. A caller that exhaustively pattern-matches on
  `{:error, :timeout} | {:error, {:exit, _}}` would break on the
  new `{:error, {:partial_overflow, _}}` tuple.
- **Rebuttal (R):** If any current caller of `recv/2` matches
  errors exhaustively rather than with a catch-all, the new tuple
  is technically a breaking change. The solution does not enumerate
  the call sites of `recv/2` to confirm this.
- **Backing (B):** `Tau.MCP.Transport` behaviour module; OTP
  convention that `{:error, _}` is open-set unless the typespec
  uses a closed union.

#### Falsification attempt for claim 5

- **Strategy:** dependency check on `recv/2` callers within the
  repo.
- **Attempt:** Searched the repo for callers of
  `Tau.MCP.Transport.*.recv` — the typical caller is the MCP
  GenServer wrapping the transport, which is upstream of this
  validation's scope. The solution itself does not enumerate
  callers but the open-set `{:error, _}` convention is
  conservative.
- **Outcome:** withstood under the open-set qualifier — no
  enumerated counter-example. If a caller turns out to enumerate
  error atoms exhaustively, that caller needs a one-line
  catch-all, but it is not the validator's role to confirm by
  searching the entire MCP GenServer integration. Recorded under
  Outstanding doubts.
- **Action:** none; flag for parent.

### Claim 6: `bash.ex`'s `truncate/3` is preserved as a no-op-in-cap-reached safety net

- **Claim (C):** "`lib/tau/tools/builtin/bash.ex`'s `truncate/3` — it
  still runs after `collect_port/3` returns; the in-loop cap now
  ensures `truncate/3` always receives a buffer that is already
  within bounds, making `truncate/3` a no-op in the cap-reached
  path. No callers of `truncate/3` change."
- **Grounds (G):** `truncate/3` is defined at `bash.ex:104-129`
  with the cap test `bytes <= @max_bytes and line_count <=
  @max_lines -> {output, false, nil}`. If `collect_port/3` enforces
  `acc_bytes >= @max_bytes` and slices to exactly `@max_bytes`
  before returning, the post-loop `truncate/3` call satisfies
  `bytes <= @max_bytes` and returns the input unchanged — the
  no-op branch.
- **Warrant (W):** Idempotence under repeated bounded truncation:
  if a cap C is enforced twice in series with the same threshold
  C, the second application is a no-op. This is a pure-function
  property of the truncation operation.
- **Qualifier (Q):** Holds when the in-loop cap and `truncate/3`'s
  cap are numerically equal AND the line-count cap (`@max_lines =
  1000`) is also satisfied. The in-loop guard is byte-only, so if
  a `@max_bytes`-sized buffer contains > 1000 lines, `truncate/3`
  will still slice to the last 1000 lines (not a no-op for the
  line-count path).
- **Rebuttal (R):** The "no-op" framing is incomplete: `truncate/3`
  remains a non-trivial pass over the buffer when the line-count
  cap is the binding constraint. The solution overstates "no-op"
  but the correctness claim (`truncate/3` is unchanged and no
  callers need updating) survives.
- **Backing (B):** Idempotence of bounded-cap operations is a
  standard property; no external citation needed.

#### Falsification attempt for claim 6

- **Strategy:** counter-example construction on the line-count cap.
- **Attempt:** Constructed a buffer of `@max_bytes` (32 KiB) of
  single-character lines: 32_768 newlines → 32_769 line elements
  → `Enum.take(lines, -@max_lines)` keeps the last 1000 →
  `truncate/3` is NOT a no-op in this case. The buffer is sliced
  on line count even though byte count is exactly at cap.
- **Outcome:** partially falsified on the "no-op" framing; the
  correctness sub-claim ("no callers of `truncate/3` change")
  survives. The solution slightly over-claims by saying "a no-op
  in the cap-reached path" when the line-count branch is still
  live.
- **Action:** narrow qualifier in place: `truncate/3` is a no-op
  on the *byte* truncation path; it remains active on the *line*
  truncation path. No solution revision required because the
  "no callers change" core claim is unaffected.

### Claim 7: No new processes, supervisors, or application children are introduced

- **Claim (C):** "The supervision tree — no new processes,
  supervisors, or application children."
- **Grounds (G):** The chosen approach (`Tau.IO.Port.close_if_open/1`
  as a pure exported function) introduces no `use GenServer`, no
  `start_link/1`, no application child spec. The rejected
  Proposal 3 was an OTP-supervised GenServer approach that the
  selection explicitly avoided; the hybrid takes only the
  `close_if_open/1` extraction element from Proposal 1.
- **Warrant (W):** Tau OTP non-negotiable #3 ("MUST NOT wrap
  stateless logic in a GenServer") and #8 ("Pure functions are
  the default; processes are the exception"). A two-line liveness
  check is stateless logic; making it a pure function is the
  prescribed shape.
- **Qualifier (Q):** Holds unconditionally for the proposed
  artefact.
- **Rebuttal (R):** none — universal because the proposed
  artefact is a pure function with no supervision implications;
  the rebuttal class would be "the artefact secretly requires a
  process," which inspection of the function body rules out.
- **Backing (B):** `.claude/rules/otp-non-negotiables.md`
  Invariants #3 and #8.

#### Falsification attempt for claim 7

- **Strategy:** type-level check on the proposed module.
- **Attempt:** The proposed `Tau.IO.Port.close_if_open/1` body
  (`if Port.info(port) != nil, do: Port.close(port); :ok`) uses
  no `Process.*`, no `:gen_server`, no message sending. It is
  type-`port() -> :ok` with side effects only on the Port
  itself. No supervision attachment is possible from this body.
- **Outcome:** withstood.
- **Action:** none.

## Cross-claim consistency

Claims are mutually consistent. The three site-specific claims
(2, 3, 4) share the same mechanism with site-specific cap values;
the helper claim (1) supports all three; the preservation claims
(5, 6, 7) are about non-changes downstream of the three site
fixes. The only tension worth noting:

- Claims 3 and 4 both assert a specific cap value (32_768 and
  65_536) without strong backing. The solution acknowledges
  Claim 3's value as an open question; Claim 4's value is asserted
  without similar acknowledgement. This is an asymmetry of rigour,
  not a logical inconsistency. Both should be treated as
  implementer-discretion values reviewed before merge.

## Falsification summary

| # | Claim (short) | Strategy | Outcome | Action |
|---|---|---|---|---|
| 1 | `Tau.IO.Port.close_if_open/1` replaces three try/catch sites | dependency + counter-example | withstood | none |
| 2 | `local.ex` `collect_port/3` rewrite (iolist + counter + cap) | edge-case + type-level | withstood | none |
| 3 | `hooks/shell.ex` `collect/3` rewrite + `@max_output_bytes 32_768` | prior-art + edge-case | partially falsified (value) | narrow qualifier — implementer confirms cap value before merge |
| 4 | `stdio.ex` `recv/2` `{:noeol, _}` cap + `@max_partial_bytes 65_536` | dependency + counter-example | withstood | flag value for implementer review |
| 5 | `Tau.MCP.Transport` behaviour preserved | dependency check | withstood (open-set) | flag for parent — confirm callers don't enumerate errors |
| 6 | `bash.ex`'s `truncate/3` preserved as no-op | counter-example | partially falsified (framing) | narrow qualifier — no-op on byte path only |
| 7 | No new processes / supervisors | type-level | withstood | none |

## Revision required

No solution or problem revision required. Two **partial
falsifications** (claim 3 value, claim 6 framing) are addressed by
narrowing qualifiers in place — the solution's mechanism claims and
the "no-callers-change" sub-claim of claim 6 survive. The
solution's existing Open Questions section (questions #1–#4)
already captures the territory the partial falsifications cover;
the validator's contribution is to mark question #2 (hook cap
value) as a **merge blocker** rather than a passing implementer
note.

- **Target file:** n/a (no revision)
- **Revision kind:** n/a
- **Rationale:** All seven claims pass with narrowed qualifiers
  where applicable. The remaining doubts are implementer-decision
  items that the solution's open-questions section already
  enumerates; they do not falsify the proposed approach itself.

## Outstanding doubts

Inherited by the parent validator:

- **Hook output cap value.** `@max_output_bytes 32_768` lacks a
  policy backing. A hook emitting >32 KiB JSON will silently
  truncate and the `Jason.decode/1` failure path swallows the
  truncation into `:cont`. Implementer MUST confirm the value
  against the hook-runner opts interface before merging; the
  parent's solution should reflect this as a constraint on the
  hook subsystem rather than a free-running implementer
  decision.
- **MCP `recv/2` callers' error-handling specificity.** Claim 5
  (behaviour-contract preservation) holds under the open-set
  `{:error, _}` convention. If any caller exhaustively matches
  error atoms, the new `{:error, {:partial_overflow, _}}` tuple
  is a breaking change. Worth a one-grep confirmation in the
  implementation PR.
- **UTF-8 codepoint boundary on `binary_part(0, max_bytes)`.**
  Solution open question #4 — the in-loop truncation at exact
  byte count may split a multi-byte codepoint, producing an
  invalid UTF-8 binary. The acceptance criterion does not
  require clean codepoint boundaries, but downstream consumers
  (telemetry, logging, JSON encoding) may. Worth a defensive
  `String.chunk(:valid)` or similar at the cap-reached boundary
  before returning.
- **`@max_bytes` migration direction (open question #1).** The
  solution promotes `@max_bytes` from `bash.ex:35` to `local.ex`
  as a module attribute. The reverse dependency (Bash tool
  reading `local.ex`'s constant) is unusual — typically the tool
  owns its policy and the operations layer reads it. The
  implementer may want to keep `@max_bytes` in `bash.ex` and
  thread it as a parameter to `bash/2` instead, preserving the
  policy-at-tool-level convention.
