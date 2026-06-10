---
template_version: 1
template_name: proposal
proposal_id: 4
parent_problem: ../problem.md
---

# Proposal 4: Extract a SafePlug wrapper behaviour that encodes the no-raise invariant at the call site

## Approach

Introduce a `Tau.CodingAgent.TauContext.SafePlug` behaviour module with a
`safe_call/2` callback. `Router` implements this behaviour; `SafePlug.wrap/3`
is the single outer guard: it delegates to the implementation's `safe_call/2`
and its own `rescue` is the only location where the no-raise invariant is
enforced. `Router.call/2` is renamed to `Router.safe_call/2`; the outer
`rescue` migrates from `call/2` into `SafePlug.wrap/3`; and `Router.call/2`
becomes a one-liner delegation `SafePlug.wrap(__MODULE__, conn, opts)`.
The inner `dispatch/2` rescue/catch are retained unchanged. The result is a
single, named, tested boundary rather than an anonymous outer rescue that
accidentally covers an unspecified set of paths.

## Rationale

The complection is: the outer rescue's scope is ambiguous because it lives
inside `call/2` alongside route dispatch logic. This proposal separates the
concerns by extracting the "ensure Plug never raises" invariant into a named
module (`SafePlug`) that exists solely to enforce D-035 at the Plug boundary.
`Router` no longer mixes routing and crash containment; the crash containment
lives in `SafePlug.wrap/3`. Any future Plug that needs D-035 compliance can
use the same wrapper, making the invariant reusable and independently testable.
This is a behaviour-preserving refactor on the public API (`call/2` still works)
but the internal structure is decomplected.

## Sketch

```elixir
# lib/tau/coding_agent/tau_context/safe_plug.ex  (new file)

defmodule Tau.CodingAgent.TauContext.SafePlug do
  @moduledoc """
  Wrapper that enforces D-035: a Plug's `call/2` must never raise.

  Any Plug that must honour D-035 implements `safe_call/2` and delegates
  its `call/2` to `SafePlug.wrap/3`. The rescue lives here, not in the
  implementing Plug.
  """

  @rpc_version "2.0"

  @callback safe_call(Plug.Conn.t(), any()) :: Plug.Conn.t()

  @spec wrap(module(), Plug.Conn.t(), any()) :: Plug.Conn.t()
  def wrap(mod, conn, opts) do
    mod.safe_call(conn, opts)
  rescue
    # D-035 hard guard. Named and isolated here so Router.safe_call/2
    # contains routing logic only. safe_call/2 implementations MUST NOT
    # have their own outer rescue; each inner guard handles its own scope.
    e ->
      alias Plug.Conn
      body =
        case Jason.encode(%{
               "jsonrpc" => @rpc_version,
               "error" => %{"code" => -32_603,
                            "message" => "router exception: " <> Exception.message(e)}
             }) do
          {:ok, b} -> b
          _ -> ~s({"error":"json encode failed"})
        end

      conn
      |> Conn.put_resp_content_type("application/json")
      |> Conn.send_resp(500, body)
  end
end
```

```elixir
# lib/tau/coding_agent/tau_context/router.ex (changes only)

@behaviour Plug
@behaviour Tau.CodingAgent.TauContext.SafePlug

# call/2: one-liner; routing logic now in safe_call/2 below.
@impl Plug
def call(%Conn{} = conn, opts), do: SafePlug.wrap(__MODULE__, conn, opts)

# safe_call/2: pure routing, no outer rescue.
@impl SafePlug
def safe_call(%Conn{} = conn, opts) do
  case {conn.method, conn.path_info} do
    {"GET", ["healthz"]} -> send_text(conn, 200, "ok")
    {"POST", ["mcp"]}    -> handle_mcp(conn, opts)
    {"GET", ["mcp"]}     -> send_json(conn, 405, ...)
    _                    -> send_text(conn, 404, "not found")
  end
end
# dispatch/2's rescue/catch retained unchanged.
```

```elixir
# test/tau/coding_agent/tau_context/safe_plug_test.exs (new file)

defmodule Tau.CodingAgent.TauContext.SafePlugTest do
  use ExUnit.Case, async: true
  use Plug.Test

  defmodule AlwaysRaisePlug do
    @behaviour Plug
    @behaviour Tau.CodingAgent.TauContext.SafePlug

    def init(opts), do: opts
    def call(conn, opts), do: SafePlug.wrap(__MODULE__, conn, opts)
    def safe_call(_conn, _opts), do: raise("boom")
  end

  test "SafePlug.wrap catches raise and returns JSON-RPC 500" do
    conn = conn(:post, "/mcp", "")
    result = SafePlug.wrap(AlwaysRaisePlug, conn, %{})
    assert result.status == 500
    {:ok, body} = Jason.decode(result.resp_body)
    assert body["jsonrpc"] == "2.0"
    assert body["error"]["code"] == -32_603
    assert body["error"]["message"] =~ "boom"
  end
end
```

## Tradeoffs

### Strengths

- D-035 is now a named, tested module (`SafePlug`), not an anonymous rescue
  inside a routing function. The invariant is discoverable and reusable.
- `Router.safe_call/2` contains routing logic only; `SafePlug.wrap/3` contains
  crash containment only — the complection is structurally eliminated.
- The property test on `SafePlug` is simple and deterministic (use an
  `AlwaysRaisePlug`); no awkward `:persistent_term` injection needed.
- Future Plugs in the subsystem can adopt the same wrapper; the pattern
  propagates the D-035 invariant at zero marginal cost.
- Satisfies option (b) of the acceptance criterion: the outer rescue is
  retained but explicitly scoped and tested.

### Weaknesses

- Introduces a new file (`safe_plug.ex`) and a new behaviour for what is
  currently a single call site — possibly over-engineering for a single Plug.
- The `SafePlug` behaviour adds an indirection layer; the routing path in tests
  now goes `call → wrap → safe_call`, which can confuse stack traces.
- The callback `safe_call/2` is a public function (required by behaviour
  dispatch) but it is semantically internal — callers can invoke it directly
  bypassing the rescue, which is undesirable. This is a Plug/behaviour
  limitation with no clean fix short of a macro.
- `Router.call/2` being a delegation wrapper means Plug.Test's `conn/3`-based
  tests work, but any test that directly calls `Router.safe_call/2` bypasses
  D-035 enforcement.

### Costs

- 1 new file (`safe_plug.ex`, ~45 lines).
- 1 new test file (`safe_plug_test.exs`, ~25 lines).
- `router.ex` diff: ~15 lines changed (rename `call/2` body to `safe_call/2`,
  add delegation, add `@behaviour SafePlug`).
- No API or supervisor changes.
- No CI plumbing changes.

## Dependencies

- No new library dependencies.
- No other subproblem solutions are prerequisites.
- If other Plugs in the subsystem are to be migrated to `SafePlug`, they
  become optional follow-on work (out of scope here).

## Confidence

medium — the behaviour extraction is mechanically straightforward. Confidence
would rise to high after verifying that Plug.Test dispatches correctly through
the `call → wrap → safe_call` chain (one prototype test run needed).

## Prior art / references

- Plug.ErrorHandler (in the Plug library): the canonical "wrap a Plug call in
  a rescue and convert exceptions to responses" pattern; `SafePlug` is a
  smaller, project-local version.
- Phoenix.Router uses a similar outer-guard pattern via `Plug.Builder.compile/3`
  wrapping the pipeline in a rescue before delegating to the generated `call/2`.
- Elixir behaviour docs: `@callback` for enforcing a contract on implementing
  modules.
