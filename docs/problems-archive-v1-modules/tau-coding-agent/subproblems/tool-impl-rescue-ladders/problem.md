---
template_version: 1
template_name: problem
node_kind: leaf
depth: 1
parent: ../../problem.md
status: draft
---

# Problem: tools.ex rescue ladders make infrastructure errors indistinguishable from legitimate absences

## Statement

Three private helpers in `Tau.CodingAgent.TauContext.Tools`
(`lib/tau/coding_agent/tau_context/tools.ex`) each wrap fallible operations in
`rescue`/`catch` and return the same `{"available": false, "reason": "..."}` JSON
envelope whether the failure is an infrastructure error (process crash, bad API
shape) or a legitimate absence (feature not configured, session not found). A
coding-agent subprocess that receives `available: false` cannot tell whether it
should retry, report to the user, or accept a permanent limitation, because the
error surface is identical for both classes.

## Context

- Lines 215–229 (`tau_session_status/1`): `Tau.Session.snapshot/1` can return
  `{:error, :not_found}` (handled explicitly) but the surrounding `rescue`/`catch`
  absorbs any other exception into `{"available": false, "reason": "snapshot error:
  ..."}` — same envelope as a legitimately-absent session.
- Lines 272–283 (`safe_memory_load/1`): wraps `MemoryLoader.load/1` in
  `rescue`/`catch` and maps all errors to `{:error, "memory loader failed: ..."}`,
  which the caller encodes as `{"available": false}` — same envelope as "no
  memory files in cascade".
- Lines 371–379 (`session_cwd/1`): `rescue`/`catch` around
  `Tau.Session.snapshot/1` returns `nil`, which callers treat as "fall back to
  `File.cwd!/0`" — silently masking a session ID lookup failure as a missing cwd.
- D-035 comment in the module's `@moduledoc`: "Every public function in this
  module catches its own errors and returns a tagged tuple." The private helpers
  implement this contract, but the `rescue`/`catch` ladders absorb error
  information rather than tagging it distinctly.
- The three helpers are independent: `session_cwd/1` is called from
  `tau_memory_query/2`; `safe_memory_load/1` is its inner helper; the
  `tau_session_status/1` `rescue` block is self-contained. No fix to one
  requires changes to another.

## Complecting hypothesis

1. Tool-response shaping is complected with optional-capability guarding:
   each `rescue`/`catch` ladder maps both "infrastructure broke" and "feature
   absent" to `{"available": false}`, so the two are indistinguishable at the
   call site.
2. `session_cwd/1`'s rescue block is complected with the cwd-fallback logic: a
   session lookup crash and a `nil` session_id produce the same `nil` return,
   pushing an undetected crash silently into the `File.cwd!/0` fallback.

## Decomposition strategy

(leaf — no further decomposition; proceed to proposals)

## Acceptance criterion

The three rescue sites in `tools.ex` are replaced with patterns where
infrastructure errors (unexpected exceptions, thrown terms) produce a response
that is structurally distinguishable from legitimate absences, or are removed
because the calling code can rely on the OTP process model instead of
pre-emptive rescue.

## Out of scope

- The `expose_tau_context?/0` rescue in `dispatcher.ex` (sibling sub-problem
  `settings-feature-flag-access` owns that site).
- The `close_port/1` rescue in `claude_code.ex` (sibling sub-problem
  `port-lifecycle-rescue`).
- The outer rescue in `Router.call/2` (sibling sub-problem `router-outer-rescue`).
- Changes to the MCP wire format or the D-035 public contract.
- The `safe_start/3` / `safe_cancel/2` adapter-boundary wrappers in
  `dispatcher.ex` (excluded at root out-of-scope).

## Amendment log

- (none yet)
