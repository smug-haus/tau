---
template_version: 1
template_name: problem
node_kind: leaf
depth: 1
parent: ../../problem.md
status: draft
---

# Problem: close_port/1 uses a bare catch around a TOCTOU-guarded Port.close

## Statement

`Tau.CodingAgents.ClaudeCode.close_port/1`
(`lib/tau/coding_agents/claude_code.ex:402–416`) checks `Port.info/1` to test
whether the port is still open, then calls `Port.close/1` in a separate step,
wrapping the close call in `catch _, _ -> :ok`. Because the liveness test and
the close are non-atomic, the TOCTOU window the `catch` is defending against
was created by the function itself; meanwhile the catch discards the error
silently, making it impossible to distinguish "port was already closed" from "an
unexpected runtime error occurred".

## Context

- `lib/tau/coding_agents/claude_code.ex:402–416`:

  ```elixir
  defp close_port(port) when is_port(port) do
    try do
      if Port.info(port) do
        Port.close(port)
      end
    catch
      _, _ -> :ok
    end
    :ok
  end
  ```

- `Port.close/1` raises `ArgumentError` if the port is already closed, which
  is the only error that `Port.info/1` → `nil` branch is guarding against.
  The standard idiom is to match on `Port.info/1` returning `nil` and skip
  `Port.close/1`, without a rescue/catch at all, or to use `Port.close/1`
  directly and match the `ArgumentError` if "already closed" is the only
  expected failure mode.
- The function is called from `port_done/1` (stream cleanup) and from
  `port_next/2`'s cancel branch; both call sites treat the return as
  informational (`:ok` either way).
- The OTP non-negotiables (rule 7) state: "Let it crash; supervise; restart.
  MUST NOT `try/rescue` across process boundaries." A Port is an OS process
  wrapped in a BEAM port; `Port.close/1` on a dead port is not a
  cross-process-boundary event — it is a local error that can be handled with
  a guard clause.

## Complecting hypothesis

Port close is complected with Port liveness testing: `close_port/1` performs a
`Port.info/1` guard to avoid an `ArgumentError`, then catches the very exception
it just guarded against — meaning the guard serves no purpose and the catch is
disguising a TOCTOU structure the function itself introduced.

## Decomposition strategy

(leaf — no further decomposition; proceed to proposals)

## Acceptance criterion

`close_port/1` does not use `try/catch` or `try/rescue`; it handles the
"already closed" case via a guard or pattern match that does not create a
TOCTOU window, and any unexpected error from `Port.close/1` propagates rather
than being swallowed.

## Out of scope

- The `expose_tau_context?/0` rescue in `dispatcher.ex` (sibling sub-problem
  `settings-feature-flag-access`).
- The rescue ladders in `tools.ex` (sibling sub-problem
  `tool-impl-rescue-ladders`).
- The outer rescue in `Router.call/2` (sibling sub-problem
  `router-outer-rescue`).
- `cancel/1` in `claude_code.ex`, which intentionally returns `:ok` with no
  logic (the doc explains this).
- Stream-resource `after_fun` teardown beyond `port_done/1`.

## Amendment log

- (none yet)
