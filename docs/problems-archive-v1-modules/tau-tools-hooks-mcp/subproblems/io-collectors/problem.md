---
template_version: 1
template_name: problem
node_kind: leaf
depth: 1
parent: ../../problem.md
status: draft
---

# Problem: io-collectors — Three hand-rolled receive loops accumulate without an in-loop byte cap

## Statement

`Tau.Tools.Operations.Local.bash/2`, `Tau.Hooks.Shell.collect/3`, and
`Tau.MCP.Transport.Stdio.recv/2` each implement a hand-rolled `receive` loop
that accumulates Port output via `acc <> data` with no byte cap inside the loop
body. The truncation policy (where it exists) is applied only after the process
exits or the loop terminates; a command that writes continuously — or one that
never exits — accumulates without bound until the BEAM OOMs or the session
times out. The three collectors also duplicate the same `try/catch` pattern
around `Port.close/1` for timeout recovery, spreading the same non-idiomatic
error-handling across three sites.

## Context

- `lib/tau/tools/operations/local.ex:96-165` — `bash/2` and `collect_port/3`:
  accumulates stdout as `acc <> data`; no mid-loop cap; cap applied in
  `Bash.truncate/3` only after port closes. O(n²) binary concatenation on large
  outputs. `try/catch` around `Port.close/1` at line 157.
- `lib/tau/hooks/shell.ex:145-160` — `collect/3`: same `acc <> data` pattern,
  same `try/catch` around `Port.close/1` at line 151.
- `lib/tau/mcp/transport/stdio.ex:65-78` — `recv/2`: does not accumulate across
  calls (`:line`-framed port), but the `{:noeol, partial}` branch accumulates
  `state.partial <> partial` across recursive calls with no length cap. Same
  `try/catch` around `Port.close/1` at line 82.
- Flat audit: `.code_audit/archive/v1-flat/03-tools-hooks-mcp.md` critical
  finding at `local.ex:77-115` — "A misbehaving command will OOM the BEAM
  before the truncation logic ever sees the buffer."
- `lib/tau/tools/builtin/bash.ex:9-10` — documents a 1000-line / 32 KiB
  truncation cap, but this cap is not enforced until `truncate/3`, which runs
  only when `collect_port/3` has already returned the full accumulated buffer.

## Complecting hypothesis

**The collection strategy (binary accumulation + Port framing) is complected
with the process lifecycle and the termination policy** because the decision
"when to stop accumulating" is encoded as "when the port exits", with the memory
bound applied as an afterthought. A well-structured collector would enforce the
bound as a loop invariant, terminating the port when the cap is exceeded, so the
accumulation strategy and the truncation policy are the same mechanism rather
than two sequential passes.

## Decomposition strategy

(leaf — no further decomposition; proceed to proposals)

## Acceptance criterion

The problem is solved when: (a) `collect_port/3` (or its replacement) enforces
the `@max_bytes` cap inside the receive loop and closes the Port when the cap is
reached without waiting for command exit; (b) `hooks/shell.ex`'s collector and
`mcp/transport/stdio.ex`'s partial accumulator each apply an equivalent cap
before returning; and (c) `try/catch` around `Port.close/1` is replaced at all
three sites with a guard that checks port liveness before closing (e.g.
`if Port.info(port), do: Port.close(port)`) — all three verifiable by a test
that pipes a stream exceeding the cap to Bash and asserts the result is bounded
and the process does not crash.

## Out of scope

- The SSE transport's in-loop receive (`mcp/transport/sse.ex`) — SSE frames
  arrive via a Finch streaming callback, not a hand-rolled receive loop; its
  issues (unlinked task, duplicate accept header) are a concurrency concern
  covered by the `mcp-server-concurrency` sub-problem.
- The `Delegate` tool's `do_drain/4` receive loop — it accumulates typed event
  structs, not raw binary; it has its own deadline-based timeout; its memory
  profile is bounded by the event count, not raw bytes.
- The `Agent` tool's `await_child/4` receive loop — same; it processes typed
  PubSub events, not raw binary accumulation.
- Shell injection via `{:spawn, cmd}` in `Hooks.Shell` — a security concern
  separate from the collection bound.

## Amendment log

- (none yet)
