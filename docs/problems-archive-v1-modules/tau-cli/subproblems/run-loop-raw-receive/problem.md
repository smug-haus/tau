---
template_version: 1
template_name: problem
node_kind: leaf
depth: 1
parent: ../../problem.md
status: draft
---

# Problem: drain_run_loop uses hand-rolled receive instead of PubSub stream

## Statement

`Tau.CLI.drain_run_loop/2` and `drain_session_end/2` consume PubSub events
via raw `receive` loops with a wildcard catch-all (`_ -> drain_run_loop/2`)
that silently discards every `Events.*` struct not in their explicit allowlist.
`drain_session_end/2` uses `receive after 10_000 -> exit_code`, returning the
caller-seeded exit code on timeout — meaning a failed `SessionEnd` flush is
reported as success. Both patterns violate OTP non-negotiable #4 (cross-process
events must not be consumed via raw `receive`) and #7 (no `try/rescue` across
process boundaries).

## Context

- `lib/tau/cli.ex:427–486` — `drain_run_loop/2`: handles `MessageEnd`,
  `SessionEnd`, `ToolStart`, `ToolEnd`; wildcard `_ ->` clause recurses,
  discarding `MessageStart`, `MessageUpdate`, `SessionStart`, `SystemNotice`,
  `SkillActivated`, `Cancelled`, `ToolUpdate` and any future `Events.*` structs.
- `lib/tau/cli.ex:489–497` — `drain_session_end/2`: `receive after 10_000 ->
  exit_code` — returns the given `exit_code` on timeout instead of signalling
  the flush failure.
- The moduledoc at `lib/tau/cli.ex:36–46` acknowledges that `Tau.stream/2`
  cannot be used here due to D-004 subscribe-before-start semantics, but the
  chosen alternative (hand-rolled `receive`) violates the project's own
  event-abstraction rules.
- `run_cmd/1` at `lib/tau/cli.ex:344–362` wraps `Tau.send/2` in `try/after`
  solely to guarantee telemetry-handler detachment — this is legitimate use of
  `try/after` but is coupled to the hand-rolled loop.
- OTP non-negotiable #4: "Cross-process events MUST use `Phoenix.PubSub` or
  monitored refs."
- OTP non-negotiable #7: "MUST NOT `try/rescue` across process boundaries."

## Complecting hypothesis

- Session-event consumption is complected with progress rendering:
  `drain_run_loop/2` both drains the mailbox and inline-renders stderr
  progress lines, which is why the wildcard discard appears necessary — the
  loop is trying to do two things at once.
- Exit-code semantics are complected with flush timing: `drain_session_end/2`
  conflates "we timed out waiting" with "the session ended cleanly at the
  exit code the caller chose", producing a silent false-positive on flush
  failure.

## Decomposition strategy

(leaf — no further decomposition; proceed to proposals)

## Acceptance criterion

`tau run` drives the headless session without a raw `receive` loop; unknown
`Events.*` structs are not silently discarded; a missing `SessionEnd` within
the drain window results in a non-zero exit code rather than the caller-seeded
success code; the D-004 subscribe-before-start invariant is preserved.

## Out of scope

- `safe_list/safe_reload` rescues in Extensions and MCP (owned by
  error-swallowing-rescues)
- `validate/1` rescue in Config and Init
- `run_cmd/1` size beyond the loop extraction
- Telemetry `attach_progress_handlers/4` — its `try/after` detach wrapper
  is legitimate and is not part of this sub-problem

## Amendment log

- (none yet)
