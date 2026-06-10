---
template_version: 1
template_name: problem
node_kind: leaf
depth: 1
parent: ../../problem.md
status: draft
---

# Problem: Router.call/2 outer rescue is asserted unreachable but has no structural proof

## Statement

`Tau.CodingAgent.TauContext.Router.call/2`
(`lib/tau/coding_agent/tau_context/router.ex:56–89`) contains an outer `rescue`
block that catches any exception from the Plug dispatch path and returns a
JSON-RPC 500 response. The comment reads "Should be unreachable given the
per-handler try/catches below", but the claim rests on a code comment rather
than on structural proof — either a typespec, a property test, or a proof by
exhaustion that every path through `handle_mcp/2` and `dispatch/2` is covered
by their own error boundaries. The result is a rescue that is either genuinely
redundant (hiding the need to verify the inner guards) or genuinely necessary
(meaning the inner guards have gaps).

## Context

- `lib/tau/coding_agent/tau_context/router.ex:56–89` — the outer rescue in
  `call/2`.
- `lib/tau/coding_agent/tau_context/router.ex:218–226` — `dispatch/2` has its
  own `rescue`/`catch` around `handle_method/4`.
- `lib/tau/coding_agent/tau_context/router.ex:93–130` — `handle_mcp/2` uses
  a `with` pipeline; its `else` branches handle all expected error shapes from
  `authorize/2`, `read_request_body/1`, and `decode_json/1`.
- If `handle_mcp/2` raised unexpectedly (e.g. from `load_state/1`), the outer
  rescue would be the only guard. `load_state/1` itself is currently safe
  (pattern-matched on `:persistent_term.get`), but this is not enforced.
- D-035 ("The Plug itself never raises on bad input") names this router's
  contract but does not specify whether the outer rescue is the mechanism or
  just a backstop; the distinction matters for test coverage.

## Complecting hypothesis

The outer rescue in `Router.call/2` is complected with the per-handler error
boundaries inside `handle_mcp/2` and `dispatch/2`: the outer rescue's
correctness depends on the completeness of the inner guards, but neither is
verified against the other. A future change to `handle_mcp/2` that introduces
a new fallible path would silently rely on the outer rescue without the author
knowing the inner guard is now incomplete.

## Decomposition strategy

(leaf — no further decomposition; proceed to proposals)

## Acceptance criterion

The relationship between the outer rescue in `Router.call/2` and the inner
error boundaries in `handle_mcp/2` / `dispatch/2` is made explicit: either (a)
the outer rescue is provably unreachable by exhaustion of all fallible call
sites and is removed, or (b) the outer rescue is retained as an explicit
backstop and its scope is constrained to the specific paths the inner guards do
not cover, with a comment or test that names those paths.

## Out of scope

- The `expose_tau_context?/0` rescue in `dispatcher.ex` (sibling sub-problem
  `settings-feature-flag-access`).
- The rescue ladders in `tools.ex` (sibling sub-problem
  `tool-impl-rescue-ladders`).
- `close_port/1` in `claude_code.ex` (sibling sub-problem
  `port-lifecycle-rescue`).
- Changes to the MCP wire protocol or auth logic.
- Performance or concurrency of the `:persistent_term` state reads.

## Amendment log

- (none yet)
