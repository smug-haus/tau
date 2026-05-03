---
description: Tau OTP correctness invariants. Always loaded.
---

# Tau OTP non-negotiables

Correctness invariants, not style preferences. No violation without
written justification in the PR description.

## Invariants

1. Stateful subsystems MUST run as supervised processes. No
   module-level mutable state, no `:ets` outside an owner process, no
   `Application.put_env/3` for runtime state.
2. Extensibility seams MUST be behaviours. No abstract base classes,
   no string-keyed dispatch. Pattern match on atoms and structs.
3. MUST NOT wrap stateless logic in a GenServer.
4. Cross-process events MUST use `Phoenix.PubSub` or monitored refs.
   Never `Process.whereis/1 |> send(...)`. Never `:global`.
5. Telemetry events MUST cover everything user-visible or
   perf-sensitive. `:telemetry.execute/3` in `[:tau, ...]`; pair
   `*.start` with `*.stop` / `*.exception`.
6. Invariant-bearing modules MUST have properties before examples
   (`Permissions.Evaluator`, `Settings.Loader` merge,
   `Message.Assembler`, permission matchers — `StreamData`).
7. Let it crash; supervise; restart. MUST NOT `try/rescue` across
   process boundaries. MUST NOT catch `:exit`.
8. Pure functions are the default; processes are the exception.

## Concrete forms

- MUST NOT introduce a "Manager" / "Service" GenServer for shared
  state. Use per-entity processes or `:persistent_term` / ETS.
- MUST NOT replace `:gen_statem` with a hand-rolled `receive` loop.
- MUST NOT add an HTTP client besides Finch / Mint.
- MUST NOT add a JSON library besides Jason.
- MUST NOT use `IO.puts/1` for logging — telemetry or `Logger`.
- MUST NOT invent a new event format mid-loop. Extend
  `Tau.Provider.Event`.
- MUST NOT swallow errors. Use tagged tuples or
  `%Tau.Provider.Event.Error{}` stream items. Never raise on user
  input.
- MUST NOT screen-scrape shell output in `Bash` callers. Tools return
  structured `details`.
