---
template_version: 1
template_name: proposal
proposal_id: 1
parent_problem: ../problem.md
---

# Proposal 1: Remove outer rescue by exhaustion proof via @spec + Dialyzer

## Approach

Annotate every private function reachable from `call/2` — `handle_mcp/2`,
`load_state/1`, `authorize/2`, `read_request_body/2`, `decode_json/1`,
`respond_rpc/3`, `dispatch/2`, `handle_method/4`, `handle_notification/3` —
with `@spec` declarations that exclude raise (i.e. return only tagged tuples or
plain values). Add a `dialyzer` mix alias that runs in CI. Once Dialyzer confirms
no unguarded raise paths exit any of these functions, remove the outer `rescue`
block in `call/2` entirely. Replace the deleted rescue with an explanatory
`@doc false` section-header comment citing D-035 and naming the structural
invariant: "no private callee raises; see typespecs."

## Rationale

The problem is that the outer rescue's correctness claim is asserted in a
comment, not enforced structurally. `@spec` + Dialyzer converts the assertion
into a machine-checked invariant: if a future change introduces a new raise path,
Dialyzer fails CI rather than silently relying on the outer rescue. Removing
the rescue after the proof eliminates the complection entirely — there is no
outer guard that inner guards can silently depend on. The acceptance criterion's
option (a) ("provably unreachable by exhaustion") is satisfied mechanically.

## Sketch

```elixir
# lib/tau/coding_agent/tau_context/router.ex

@spec call(Plug.Conn.t(), map()) :: Plug.Conn.t()   # no raise in return type
@impl Plug
def call(%Conn{} = conn, opts) do
  case {conn.method, conn.path_info} do
    {"GET", ["healthz"]} -> send_text(conn, 200, "ok")
    {"POST", ["mcp"]}    -> handle_mcp(conn, opts)
    {"GET", ["mcp"]}     -> send_json(conn, 405, ...)
    _                    -> send_text(conn, 404, "not found")
  end
  # outer rescue REMOVED — invariant held by typespecs below;
  # Dialyzer CI gate enforces no unguarded raise in callees (D-035).
end

@spec handle_mcp(Plug.Conn.t(), map()) :: Plug.Conn.t()
defp handle_mcp(conn, opts) do ... end

@spec load_state(map()) :: map()           # :persistent_term.get never raises
defp load_state(opts) do ... end

@spec authorize(Plug.Conn.t(), map()) :: :ok | {:error, :unauthorized}
defp authorize(conn, state) do ... end

@spec read_request_body(Plug.Conn.t(), binary()) ::
  {:ok, binary(), Plug.Conn.t()} | {:error, atom() | {atom(), term()}}
defp read_request_body(conn, acc \\ "") do ... end

@spec decode_json(binary()) :: {:ok, map() | list()} | {:error, {:parse_error, binary()}}
defp decode_json(body) do ... end

@spec dispatch(map(), map()) :: map() | :no_response
# dispatch/2's existing rescue/catch ARE retained — they are the
# per-handler guard and remain correct.
defp dispatch(...) do ... rescue ... catch ... end
```

`mix.exs` — add to `:dialyzer` plt_add_apps and enable `--warnings-as-errors`
for the `Tau.CodingAgent.TauContext.Router` module in `.dialyzer_ignore.exs`
(clearing any existing suppression on this module).

CI: add `mix dialyzer` step to the `lint` job in `.github/workflows/ci.yml`.

## Tradeoffs

### Strengths

- Satisfies acceptance criterion option (a) (provably unreachable) without any
  behavioural change — zero regression risk.
- The proof is machine-checked by Dialyzer on every future PR touching this
  module; the comment-assertion problem cannot recur.
- No new runtime code path; no change to dispatch logic.
- `dispatch/2`'s rescue/catch is explicitly preserved and its purpose remains
  unambiguous.

### Weaknesses

- Dialyzer's success typing is not a full proof of no-raise: it can miss raises
  inside `:persistent_term.get/2` or Cowboy internals if those functions are
  not in the PLT with accurate specs. The proof is only as strong as the PLT.
- Adding `@spec` to all private helpers is mechanical but verbose — ~10
  annotations spanning 30–40 lines.
- Dialyzer PLT builds are slow (~2–4 min cold); CI wall time increases.
- If `Jason.encode/1` raises on a pathological value (it shouldn't, but it's an
  external dep), Dialyzer may not catch it.

### Costs

- ~10 `@spec` annotations added across the module.
- CI job extended by Dialyzer PLT build time (~2 min warm, ~8 min cold).
- `.dialyzer_ignore.exs` may need updating if existing suppression entries
  reference this module.
- No consumer API changes; no test rewrites.

## Dependencies

- Dialyzer must be runnable in CI (OTP 27.2 includes it; no new dep).
- The existing PLT must be seeded with Jason, Plug, and Cowboy specs — standard
  for an Elixir project.
- No other subproblem solutions are prerequisites.

## Confidence

medium — the approach is correct in principle and widely used in Elixir/OTP
projects. Confidence would rise to high after a Dialyzer dry-run confirms no
false-positives in the current codebase (specifically, that `Conn.send_resp/3`
and `Jason.encode/1` are already spec'd cleanly in their PLTs).

## Prior art / references

- Elixir core library: all public Plug callbacks are `@spec`-annotated and
  Dialyzer-clean in Phoenix.
- OTP design principles: typespec-as-contract is the idiomatic structural proof
  in the BEAM ecosystem.
- `mix dialyzer` (Dialyxir): standard Elixir project tooling.
