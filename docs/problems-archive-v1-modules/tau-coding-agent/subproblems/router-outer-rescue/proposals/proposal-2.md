---
template_version: 1
template_name: proposal
proposal_id: 2
parent_problem: ../problem.md
---

# Proposal 2: Retain outer rescue as an explicit named backstop with a property test

## Approach

Keep the outer `rescue` in `call/2` but promote it from a silent fallback to
an explicitly-scoped backstop. Rename it with a module-attribute constant
`@outer_rescue_scope` listing the exact paths the inner guards do NOT cover
today, and add a `ExUnit` property test (using `StreamData`) that injects
synthetic crashes at each of those paths and asserts the outer rescue fires
correctly. The comment is replaced by a structured annotation that names the
one real gap: `load_state/1` calling `:persistent_term.get/2`, which today has
no rescue of its own. Optionally, add a minimal guard inside `load_state/1`
to narrow the outer rescue's scope further.

## Rationale

The problem is that the outer rescue's claim ("unreachable") is unverified
and its scope is ambiguous. This proposal takes option (b) from the acceptance
criterion — retain the backstop, but constrain its scope explicitly and test
it. A property test that deliberately forces the rescue path proves the rescue
is live and correctly scoped; a module-attribute annotation enumerates the
paths it covers so a future author cannot add a new fallible path without
seeing the annotation. The complection is reduced (inner vs outer scopes are
now named and tested) without the risk of removing a guard that may be
genuinely needed.

## Sketch

```elixir
# lib/tau/coding_agent/tau_context/router.ex

# Named scope: the outer rescue covers ONLY load_state/1's
# :persistent_term.get call, which has no inner guard. All paths
# through handle_mcp/2 after load_state/1 are covered by the
# with-else pipeline; dispatch/2 has its own rescue/catch.
# If load_state/1 is ever hardened (e.g. its own rescue), remove
# this outer rescue.
@outer_rescue_scope [:load_state]

@impl Plug
def call(%Conn{} = conn, opts) do
  case {conn.method, conn.path_info} do
    {"GET", ["healthz"]} -> send_text(conn, 200, "ok")
    {"POST", ["mcp"]}    -> handle_mcp(conn, opts)
    {"GET", ["mcp"]}     -> send_json(conn, 405, ...)
    _                    -> send_text(conn, 404, "not found")
  end
rescue
  # Backstop for @outer_rescue_scope paths only (see annotation above).
  # dispatch/2 and handle_mcp/2's with-else cover all other paths.
  e ->
    send_json(conn, 500, %{
      "jsonrpc" => @rpc_version,
      "error" => %{"code" => -32_603,
                   "message" => "router exception: " <> Exception.message(e)}
    })
end
```

```elixir
# test/tau/coding_agent/tau_context/router_outer_rescue_test.exs

defmodule Tau.CodingAgent.TauContext.RouterOuterRescueTest do
  use ExUnit.Case, async: true
  use Plug.Test

  import Mox

  # Verifies the outer rescue fires when load_state/1 raises, and that
  # the response is a well-formed JSON-RPC 500 (D-035 contract).
  test "outer rescue fires on load_state crash and returns JSON-RPC 500" do
    opts = Router.init(%{state_ref: :__nonexistent_term__})
    conn = conn(:post, "/mcp", ~s({"jsonrpc":"2.0","method":"ping","id":1}))
           |> put_req_header("content-type", "application/json")

    # Poison the persistent_term lookup so load_state/1 receives a key
    # whose get/2 default is bypassed by injecting a process-level override
    # via :persistent_term.put — then immediately delete it to force ArgumentError.
    :persistent_term.put(:__nonexistent_term__, :poison)
    :persistent_term.erase(:__nonexistent_term__)

    # Force the raise by using a fake key that makes :persistent_term.get raise
    # (ArgumentError on bad key type works for this test).
    opts_bad = Router.init(%{state_ref: {:bad, :tuple, :key}})

    # Use :meck or direct call; here we test via the Plug interface.
    # The key point: response must be 500 with jsonrpc error body, not a crash.
    conn = Router.call(conn, opts_bad)
    assert conn.status == 500
    {:ok, body} = Jason.decode(conn.resp_body)
    assert body["jsonrpc"] == "2.0"
    assert body["error"]["code"] == -32_603
  end

  # Property: for any malformed opts map, call/2 never raises.
  property "call/2 never raises regardless of opts shape" do
    check all opts <- StreamData.map_of(StreamData.atom(:alphanumeric),
                                        StreamData.term()) do
      conn = conn(:post, "/mcp", "")
      result = try do
        Router.call(conn, opts)
        :ok
      rescue
        _ -> :raised
      end
      assert result == :ok
    end
  end
end
```

## Tradeoffs

### Strengths

- Satisfies acceptance criterion option (b): the outer rescue is retained and
  its scope is named and tested.
- No risk of silently exposing a crash path: the guard remains active.
- The `@outer_rescue_scope` annotation is visible to `grep` and code review,
  making future scope expansion detectable.
- The property test exercises the full `call/2` Plug interface, not a hand-
  built struct; it satisfies the user-facing path requirement.

### Weaknesses

- Does not remove the complection — inner and outer guards still coexist; the
  naming improvement reduces ambiguity but does not eliminate the dual-guard
  structure.
- The property test relies on being able to force a raise through `load_state/1`
  in a test environment; `:persistent_term` semantics make injection slightly
  awkward (see sketch above — the exact mechanism may need refinement).
- A future author could add a new fallible path and forget to update
  `@outer_rescue_scope`; the annotation is advisory, not enforced.
- The test exercises the rescue path but does not prove the inner guards are
  exhaustive — it only verifies the outer rescue works when reached.

### Costs

- 1 new test file (~50 lines).
- Minor comment/annotation rewrite in `router.ex` (~10 lines changed).
- No API changes; no consumer disruption.
- CI: test suite gains one property test (fast, <1 s).

## Dependencies

- `StreamData` is already a dev dependency in this project (used elsewhere for
  property tests).
- No other subproblem solutions are prerequisites.

## Confidence

medium — the approach is straightforward. Confidence would rise to high after
confirming the exact mechanism for forcing `load_state/1` to raise in a test
context (`:persistent_term` edge cases need a prototype run).

## Prior art / references

- Plug documentation: the Plug behaviour contract does not prevent outer rescue;
  `Plug.ErrorHandler` uses a similar documented-backstop pattern.
- OTP design principles: explicit scope annotation on catch-all handlers is
  standard in gen_server `handle_call` overflow clauses.
- `StreamData` property testing: existing usage in `test/tau/` (multiple files).
