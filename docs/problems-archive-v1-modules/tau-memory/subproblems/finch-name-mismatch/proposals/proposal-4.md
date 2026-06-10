---
template_version: 1
template_name: proposal
proposal_id: 4
parent_problem: ../problem.md
---

# Proposal 4: Replace runtime config lookup with a compile-time assertion in application.ex

## Approach

Keep `Tau.Finch` as a module (alias) and make it a registered name that
`application.ex` actually starts, OR add a compile-time guard (via a module
attribute + `@compile {:inline, ...}` or a `Mix.Config` assertion) that fails
the build if the name in `embedding_worker.ex` does not match the name in
`application.ex`. Concretely: introduce a `config/config.exs` entry that
explicitly sets `:tau, :finch_name` to `Tau.Providers.Finch`, so the
`Application.get_env/3` default is never exercised in any environment and
the configuration is overt.

## Rationale

The complecting hypothesis is that two sites can drift without a compile-time
error. Proposals 1–3 fix the runtime value but leave the drift risk latent.
This proposal eliminates the latency by ensuring the config lookup always
resolves from an explicit, checked-in value in `config/config.exs` rather
than from the default argument. The default in `Application.get_env/3` becomes
a last-resort that is never reached; a missing or wrong config entry is surfaced
in configuration review rather than at runtime. This is an interface-level
change: the configuration contract is made explicit in the config files.

## Rationale (continued)

Adding the key to `config/config.exs` also documents the configurable surface:
operators reading the file learn that `:tau, :finch_name` is a valid override
point, which they cannot discover today without reading the source. This
addresses the observability failure noted in the parent problem's complecting
hypothesis ("hidden from operators").

## Sketch

```elixir
# config/config.exs  (new key, added once)
config :tau, :finch_name, Tau.Providers.Finch
```

That is the entire change. `embedding_worker.ex` is unchanged:
`Application.get_env(:tau, :finch_name, Tau.Finch)` now resolves to
`Tau.Providers.Finch` from the config file rather than the fallback default.
The wrong default atom (`Tau.Finch`) is never reached in any Mix environment
(dev, test, prod).

Optional hardening: add a `config/test.exs` entry as well to make test
environments equally explicit:

```elixir
# config/test.exs
config :tau, :finch_name, Tau.Providers.Finch
```

Optional compile-time assertion (adds a Mix task or module body check):

```elixir
# lib/tau/application.ex — top of module, compile-time guard
@finch_name Application.compile_env(:tau, :finch_name, Tau.Providers.Finch)
# Registering the pool using the same compile_env value:
{Finch, name: @finch_name}
```

And in `embedding_worker.ex`:

```elixir
@finch_name Application.compile_env(:tau, :finch_name, Tau.Providers.Finch)
# ...
Finch.request(request, @finch_name, receive_timeout: @request_timeout_ms)
```

`Application.compile_env/3` bakes the value at compile time; a change to
`config/config.exs` requires recompilation before taking effect, which is
acceptable for a registered process name. The two `compile_env` calls will
always produce the same atom because they both read from the same config key.

## Tradeoffs

### Strengths

- Zero runtime penalty: the name is resolved at compile time (with
  `compile_env`) or at application start (with `config.exs`).
- Makes the configurable surface explicit and discoverable in `config/config.exs`.
- With `Application.compile_env/3`, the compiler warns if `config/config.exs`
  changes the value without recompiling — drift is caught at build time.
- Does not require a new module or a changed function signature.
- Documents the operator override path in the config files.

### Weaknesses

- The minimal form (just `config/config.exs`) fixes the bug but still does not
  bind `application.ex` and `embedding_worker.ex` to the same compile-time
  constant; if both use `compile_env`, they independently read the same key —
  which is correct, but introduces a subtle coupling through the config key name
  rather than a shared Elixir identifier.
- `Application.compile_env/3` makes the value immutable during a running
  system; if a test suite dynamically changes `:tau, :finch_name` via
  `Application.put_env/3`, the change will be silently ignored. Tests that rely
  on environment manipulation to mock the pool name break.
- The `config.exs`-only form still has a runtime default in the source; a reader
  unfamiliar with config precedence might still mistake the fallback atom for the
  real value.
- Does not close the drift risk if a developer changes the registration name
  in `application.ex` without updating `config/config.exs`.

### Costs

- 1–2 line addition to `config/config.exs` (and optionally `config/test.exs`).
- If `compile_env` is used: both `application.ex` and `embedding_worker.ex`
  gain a `@finch_name` module attribute (~2 lines each); the `children/0` list
  and `call_embedding_api/3` each change by one expression.
- Tests using `Application.put_env(:tau, :finch_name, ...)` must be updated
  if `compile_env` is adopted.

## Dependencies

- No library changes.
- The `compile_env` variant requires Elixir 1.10+ (already satisfied: stack
  is Elixir 1.18.1).

## Confidence

**Medium.** The `config.exs` minimal form is trivially correct. The
`compile_env` hardening is sound but adds test-environment implications worth
verifying before committing.

What would raise it: confirming that no existing test manipulates
`Application.put_env(:tau, :finch_name, ...)` at runtime (a grep would settle
this immediately).

## Prior art / references

- `Application.compile_env/3` — Elixir 1.10+ standard; used in Phoenix
  generators (`config :my_app, MyApp.Endpoint, url: [host: "localhost"]` →
  `Application.compile_env(:my_app, [MyApp.Endpoint, :url])`).
- The pattern of making implicit runtime lookups explicit via `config.exs` is
  standard in the Mix configuration guide:
  `https://hexdocs.pm/mix/Mix.Config.html`.
