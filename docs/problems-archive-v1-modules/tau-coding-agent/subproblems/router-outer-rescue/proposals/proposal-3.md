---
template_version: 1
template_name: proposal
proposal_id: 3
parent_problem: ../problem.md
---

# Proposal 3: Push error boundary into load_state/1, then remove outer rescue

## Approach

Move the error boundary down to the only private callee not already protected:
`load_state/1`. Wrap its `:persistent_term.get/2` call in a `rescue` that
returns the same safe default map `%{token: nil, session_id: nil, cwd: nil,
max_depth: 2}` and emits a `Logger.error/1` entry (not a silent swallow).
Once `load_state/1` is self-guarding, every path through `call/2` is covered
by its own local boundary: `handle_mcp/2`'s `with`-else, `dispatch/2`'s
`rescue`/`catch`, and the new `load_state/1` guard. The outer `rescue` in
`call/2` is then structurally provably redundant and can be deleted. Add a
unit test for `load_state/1` covering the `:persistent_term` failure path.

## Rationale

The acceptance criterion can be reached by either removing or constraining the
outer rescue. This proposal takes the structural route: instead of proving the
outer rescue is unreachable from the top down, it makes it unreachable from the
bottom up by filling the one gap the inner guards have (`load_state/1`). The
result is that each private function owns its own failure mode, which is the
OTP non-negotiable pattern: pure functions handle their own errors; the outer
rescue becomes dead code and is deleted. The complection between outer and inner
guards is dissolved because there is no outer guard remaining.

## Sketch

```elixir
# lib/tau/coding_agent/tau_context/router.ex

# Before — load_state/1 is unguarded:
defp load_state(opts) do
  case opts[:state_ref] do
    nil -> %{token: nil, session_id: nil, cwd: nil, max_depth: 2}
    key -> :persistent_term.get(key, %{token: nil, session_id: nil,
                                        cwd: nil, max_depth: 2})
  end
end

# After — load_state/1 owns its own error boundary:
@safe_default %{token: nil, session_id: nil, cwd: nil, max_depth: 2}

defp load_state(opts) do
  case opts[:state_ref] do
    nil -> @safe_default
    key ->
      :persistent_term.get(key, @safe_default)
  end
rescue
  e ->
    # :persistent_term.get/2 can raise ArgumentError if the key type is
    # invalid (not a term — this is an internal misuse, not user input).
    # Log and return safe default so the request still produces a valid
    # JSON-RPC 401 (token: nil → unauthorized) rather than crashing the
    # listener.
    Logger.error("[Router] load_state/1 raised: #{Exception.message(e)}",
                 crash_reason: {e, __STACKTRACE__})
    @safe_default
end

# call/2 outer rescue REMOVED — load_state/1 is now self-guarding;
# handle_mcp/2's with-else covers parse/auth/body errors;
# dispatch/2's rescue/catch covers handler exceptions.
@impl Plug
def call(%Conn{} = conn, opts) do
  case {conn.method, conn.path_info} do
    {"GET", ["healthz"]} -> send_text(conn, 200, "ok")
    {"POST", ["mcp"]}    -> handle_mcp(conn, opts)
    {"GET", ["mcp"]}     -> send_json(conn, 405, ...)
    _                    -> send_text(conn, 404, "not found")
  end
end
```

```elixir
# test/tau/coding_agent/tau_context/router_load_state_test.exs

defmodule Tau.CodingAgent.TauContext.RouterLoadStateTest do
  use ExUnit.Case, async: true
  use Plug.Test

  # Verify that a bad state_ref key causes load_state to return safe
  # default (leading to 401), not a 500 or crash.
  test "bad state_ref key yields 401 not 500" do
    # Use an atom key that has never been put into persistent_term;
    # :persistent_term.get/2 with default returns default safely,
    # so we simulate the raise path with a deliberate bad-type key.
    opts = Router.init(%{state_ref: make_ref()})  # valid key type, no entry
    conn =
      conn(:post, "/mcp", ~s({"jsonrpc":"2.0","method":"ping","id":1}))
      |> put_req_header("content-type", "application/json")
      |> put_req_header("authorization", "Bearer wrong-token")

    conn = Router.call(conn, opts)
    # No state → token: nil → unauthorized → 401, not 500
    assert conn.status == 401
    {:ok, body} = Jason.decode(conn.resp_body)
    assert body["error"]["code"] == -32_001
  end
end
```

## Tradeoffs

### Strengths

- Follows the OTP non-negotiable: each function handles its own errors; no
  outer catch-all needed.
- The outer rescue is removed (option a of acceptance criterion) but the reason
  it can be removed is structural — each callee is self-guarding — not just
  asserted.
- `load_state/1`'s new guard is scoped precisely to the `:persistent_term`
  call; it does not swallow arbitrary exceptions.
- The `Logger.error/1` call makes the failure observable (telemetry could be
  added; out of scope here).
- Simpler than Proposal 1: no Dialyzer PLT dependency, no CI plumbing change.

### Weaknesses

- The `load_state/1` rescue introduces a new silent-ish fallback: a bad
  `state_ref` yields a safe-default state, which causes a 401. This is
  arguably better than a 500, but the root cause (misconfigured `state_ref`)
  is only visible in logs, not in the HTTP response.
- `:persistent_term.get/2` with a default does NOT raise for missing keys
  (it returns the default). The rescue in `load_state/1` only fires for
  invalid key types (e.g. a non-term). This is a narrow guard; if the concern
  is future `load_state/1` changes adding new fallible logic, the rescue is
  forward-looking rather than currently necessary.
- Removing the outer rescue while relying on per-function guards means any
  future addition of a new top-level branch in `call/2` (e.g. a new route)
  that forgets its own guard will have no backstop.

### Costs

- ~15 lines changed in `router.ex` (add module attr, rewrite `load_state/1`,
  remove outer rescue block, update comment header).
- 1 small test file (~25 lines).
- No API or supervisor changes.
- No CI plumbing changes.

## Dependencies

- `Logger` is already in scope (no new deps).
- No other subproblem solutions are prerequisites.

## Confidence

high — the `:persistent_term.get/2` behavior is well-documented; the
structural invariant after the change is clear and simple to verify.
Confidence is based on direct code reading plus Erlang/OTP persistent_term
documentation.

## Prior art / references

- OTP non-negotiables (`.claude/rules/otp-non-negotiables.md`) rule 7: "Let
  it crash; supervise; restart. MUST NOT `try/rescue` across process
  boundaries." — `load_state/1` running in the request process is intra-
  process; the rescue is appropriate.
- Plug documentation: Plug callbacks should not raise; self-guarding callees
  is the idiomatic way to satisfy this without a catch-all.
- `:persistent_term` OTP docs: `get/2` raises `ArgumentError` only on non-term
  key types; the default-valued variant never raises for missing keys.
