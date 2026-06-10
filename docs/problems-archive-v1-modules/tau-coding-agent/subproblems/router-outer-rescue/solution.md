---
template_version: 1
template_name: solution
parent_problem: problem.md
node_kind: leaf
synthesised_from: [proposals/proposal-2.md, proposals/proposal-3.md]
selection_method: hybrid
revision: 0
---

# Solution: Harden load_state/1 + retain a named, tested backstop

## Recommendation

Harden `load_state/1` with its own intra-function `rescue` (logging and
returning a safe default), then retain the outer rescue in `call/2` but
rewrite it as an explicitly scoped, annotated, and property-tested backstop
that names the paths the inner guards cover and acknowledges it fires only
when an inner guard is missing or future code introduces a new fallible path.
The result satisfies acceptance-criterion option (b): the outer rescue is not
removed, but its scope is constrained and named, and both the `load_state/1`
guard and the outer backstop are exercised by tests.

## Selected from

- **Chosen:** hybrid of `proposals/proposal-2.md` (named backstop + property
  test) and `proposals/proposal-3.md` (harden `load_state/1` from the
  inside).
- **Why chosen:** Proposal 3 correctly identifies `load_state/1` as the one
  unguarded callee and fills that gap structurally — each function owns its
  own failure mode. However, proposal 3's conclusion (remove the outer rescue
  entirely) creates a forward-looking risk: any future top-level branch added
  to `call/2` that forgets its own guard will have no backstop. Proposal 2
  addresses this by retaining the outer rescue as an explicitly scoped,
  annotated backstop and adding tests that verify it fires correctly. The
  hybrid combines proposal 3's structural bottom-up hardening with proposal
  2's named-and-tested retention: `load_state/1` is self-guarding (narrowing
  the outer rescue's practical scope to near-zero), and the outer rescue is
  kept as a documented, tested safety net against future gaps rather than
  silently removed. This is more reversible than proposal 1's Dialyzer-CI
  plumbing and more conservative than proposal 3's full removal.

  Proposals 1 and 4 were rejected:
  - Proposal 1 (Dialyzer): Dialyzer's success typing is not a full no-raise
    proof — external deps and PLT gaps leave holes. The CI plumbing cost
    (PLT build time) is real and the confidence rating is only "medium."
  - Proposal 4 (SafePlug behaviour): adds a new module, a new behaviour, and
    an indirection layer for a single call site. The `safe_call/2` callback
    must be public (behaviour dispatch), which exposes a bypass path. Over-
    engineering for a single Plug.

## What changes

- `lib/tau/coding_agent/tau_context/router.ex`:
  - Extract `@safe_default` module attribute for the default state map.
  - Rewrite `load_state/1`: add an intra-function `rescue` that catches any
    exception from `:persistent_term.get/2`, logs via `Logger.error/1` with
    the exception message and stacktrace, and returns `@safe_default`.
  - Rewrite the outer `rescue` block in `call/2`: replace the existing
    comment ("Should be unreachable…") with a structured annotation listing
    `@outer_rescue_scope` as the set of paths not covered by inner guards.
    The annotation states: `load_state/1` is now self-guarding (so the outer
    rescue's practical scope is near-zero today); the backstop is retained
    explicitly for future routes or future `load_state/1` changes that might
    introduce a new fallible path without their own guard.

- `test/tau/coding_agent/tau_context/router_outer_rescue_test.exs` (new):
  - Unit test: `load_state/1` rescue path — force a bad key type (e.g.
    a function reference or a non-term) to trigger `ArgumentError` from
    `:persistent_term.get/2`; assert the function returns `@safe_default`
    and that a `Logger.error` entry is emitted.
  - Integration test: end-to-end `Router.call/2` with a poisoned `state_ref`
    yields 401 (token: nil → unauthorized) rather than 500 or a crash.
  - Property test (StreamData): for any arbitrary `opts` map passed to
    `Router.call/2`, `call/2` never raises — verifies the outer rescue fires
    when needed and the response is always a valid `Plug.Conn`.

## What does not change

- `dispatch/2`'s existing `rescue`/`catch` — retained as-is; its scope and
  purpose are already clear.
- `handle_mcp/2`'s `with`-else pipeline — no changes; it correctly handles
  all expected error shapes from `authorize/2`, `read_request_body/1`, and
  `decode_json/1`.
- The MCP wire protocol, auth logic, and HTTP routing table.
- All public API surface (`call/2` signature, Plug behaviour contract).
- `:persistent_term` read semantics and performance.
- No supervisor or application changes.

## Migration sketch

1. Add `@safe_default` module attribute; rewrite `load_state/1` with its own
   `rescue` (Logger + safe default return). Run existing tests — all should
   pass; behaviour is unchanged for the non-raise path.
2. Rewrite the outer `rescue` block in `call/2`: replace the misleading
   comment with the `@outer_rescue_scope` annotation naming what the guard
   covers and why it is retained. The rescue body is unchanged functionally.
3. Add `router_outer_rescue_test.exs` with the three tests above.
4. Run `mix test` — all tests green. Run `mix compile --warnings-as-errors`
   — no new warnings.
5. No CI plumbing changes required.

## Open questions

- The exact mechanism for forcing `load_state/1`'s `:persistent_term.get/2`
  to raise in a test context needs a prototype run — proposal 2 noted this
  same concern. If `:persistent_term.get/2` with a default never raises for
  normal-type keys (it returns the default for missing keys; only invalid key
  types raise `ArgumentError`), the unit test must use a deliberately
  invalid key type (e.g. a function reference). This is implementable but
  must be confirmed against OTP 27.2 `persistent_term` behaviour.
- If a future caller of `load_state/1` depends on specific error semantics
  (rather than safe-default fallback), the Logger-and-default behaviour of
  the new guard may be surprising. The open question is whether any future
  change to `load_state/1` should raise (letting the outer rescue handle it)
  or return a tagged error tuple. This solution assumes safe-default-fallback
  is correct for the current use case; revisit if `load_state/1` grows new
  callers.

## Linked sub-problems / proposals

- `proposals/proposal-1.md` — Dialyzer + @spec exhaustion proof: rejected
  (PLT coverage gaps; CI cost; medium confidence).
- `proposals/proposal-2.md` — Retain outer rescue as a named, tested
  backstop: partially adopted (annotation + property test).
- `proposals/proposal-3.md` — Harden load_state/1, then remove outer rescue:
  partially adopted (load_state/1 hardening); outer rescue retained rather
  than removed.
- `proposals/proposal-4.md` — SafePlug wrapper behaviour: rejected
  (over-engineering for a single Plug; safe_call/2 bypass risk).

## Revision history

- (revision 0 — initial)
