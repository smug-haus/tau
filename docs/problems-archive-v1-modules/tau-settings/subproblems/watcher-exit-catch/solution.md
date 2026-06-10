---
template_version: 1
template_name: solution
parent_problem: docs/problems/tau-settings/subproblems/watcher-exit-catch/problem.md
node_kind: leaf
synthesised_from: [proposals/proposal-1.md, proposals/proposal-4.md]
selection_method: hybrid
revision: 0
---

# Solution: Pattern-match return value + monitor post-startup crashes

## Recommendation

Delete the `try/rescue/catch` block from `maybe_start_watcher/1` and replace it
with a plain `case` on `FileSystem.start_link/1`'s return value (Proposal 1's
core change). Additionally, add `Process.monitor/1` after a successful start and
a `handle_info({:DOWN, ...})` clause in the Watcher (Proposal 4's runtime-crash
extension). The `try` block is gone; startup failures are pattern-matched as
data; a synchronous `:exit` from `start_link` propagates naturally to the
supervisor; and a post-startup `FileSystem` crash is caught by the monitor and
transitions the Watcher to degraded mode at runtime. The acceptance criterion is
fully met, and the Watcher's fault model becomes complete rather than partial.

## Selected from

- **Chosen:** hybrid of `proposals/proposal-1.md` and `proposals/proposal-4.md`
- **Why chosen:** Proposal 1 satisfies the acceptance criterion at minimum cost
  (mechanical deletion of 5 lines, no new state). It wins on migration cost,
  risk, and reversibility. However, it leaves a silent gap: a `FileSystem` crash
  *after* successful startup silently orphans the subscription with no telemetry
  and no state transition. Proposal 4 closes that gap with `Process.monitor/1` +
  `handle_info/2` — the canonical OTP pattern — at a modest cost (~15 extra
  lines, one new state field `watcher_mon`). The hybrid takes Proposal 1's
  `maybe_start_watcher/1` body exactly and adds Proposal 4's monitor plumbing in
  `init/1` and `handle_info/2`. Proposals 2 and 3 were not selected: Proposal 2
  introduces a sacrificial helper process and a hard-coded timeout, adding
  substantial complexity for no gain that the hybrid does not already cover.
  Proposal 3 introduces a behaviour seam that is architecturally sound but
  over-scoped for this problem — the `Default` impl still lets `:exit` propagate
  identically to Proposal 1, and the testability improvement it offers is a
  side-benefit, not a requirement of the acceptance criterion.

## Scoring table

| # | Fit | Decomplecting depth | Migration cost | Risk | Reversibility |
|---|-----|--------------------|--------------:|------|--------------|
| 1 | Yes | Surface | Low | Low | Easy |
| 2 | Yes | Substantial | Medium | Medium | Hard |
| 3 | Yes | Surface | Medium | Low | Easy |
| 4 | Yes | Substantial | Low | Low | Easy |
| **1+4 hybrid** | **Yes** | **Substantial** | **Low** | **Low** | **Easy** |

Notes:
- Proposal 1 is "Surface" decomplecting: it removes the forbidden `catch` but
  leaves the runtime-crash gap unaddressed.
- Proposal 4 alone is "Substantial": it separates startup failure from
  runtime failure at the control-flow level, which is the full decomplecting the
  problem statement calls for.
- The hybrid achieves Proposal 4's decomplecting depth at Proposal 1's cost,
  because Proposal 4's `maybe_start_watcher/1` body is identical to Proposal 1's.
- Proposal 2 scores "Hard" on reversibility because extracting it later would
  require removing inter-process plumbing and timeouts; the sacrificial-process
  pattern also adds stateful surface area (OTP NN #8).
- Proposal 3 scores "Surface" because the `Default` impl's crash propagation path
  is identical to Proposal 1; the behaviour seam only decomplects testability, not
  the runtime fault model.

## What changes

- `lib/tau/settings/watcher.ex`:
  - Delete the `try/rescue/catch` block in `maybe_start_watcher/1`; replace with
    a plain `case FileSystem.start_link(dirs: dirs)` with `{:ok, pid}` and
    `other ->` arms (identical to Proposal 1's sketch).
  - In `init/1`: after `maybe_start_watcher/1` returns `{:ok, pid}`, call
    `Process.monitor(pid)` and store the returned reference in state as
    `watcher_mon`.
  - Add `watcher_mon: reference() | nil` field to the Watcher's state struct
    (defaulting to `nil` in the degraded-mode branch).
  - Add `handle_info({:DOWN, ref, :process, _pid, reason}, %{watcher_mon: ref} = state)`
    clause: emits `[:tau, :settings, :watcher_degraded]` telemetry with
    `%{reason: {:fs_exit, reason}}` metadata; sets `watcher: nil, watcher_mon: nil`
    in state.
  - Extract telemetry emission into a private `emit_degraded_telemetry/1` function
    (as sketched in Proposal 4) so both the startup-failure path and the
    runtime-crash path share one callsite.

## What does not change

- `init/1`'s callers and the Watcher's public API — no signature changes.
- The degraded-mode semantics visible to `Settings.Cache` (the Watcher continues
  to set `watcher: nil` and emit `[:tau, :settings, :watcher_degraded]`).
- The existing test paths: the `dirs: []` short-circuit in `cond` fires before
  `FileSystem.start_link/1` is reached; tests using that path are unaffected.
- Debounce logic, `relevant?/1` filtering, `Settings.Cache` reload trigger — all
  explicitly out of scope.
- Supervision tree structure: no new supervised children; `FileSystem` remains
  an unlinked monitored process, not a child of the Watcher's supervisor.

## Migration sketch

Single-file, two-phase implementation: (1) replace `maybe_start_watcher/1`'s
`try` block with the plain `case` (Proposal 1's change) and confirm existing
tests pass; (2) add `Process.monitor` in `init/1`, the new state field, and
`handle_info({:DOWN, ...})` with telemetry. Both phases touch only
`lib/tau/settings/watcher.ex`. No migrations, no config changes, no library
additions. The `{:DOWN, ...}` path can be unit-tested by sending a synthetic
`{:DOWN, ref, :process, pid, :killed}` message to the running Watcher via
`send/2` in a test.

## Open questions

- **Supervisor restart strategy for the Watcher**: if `FileSystem.start_link/1`
  exits synchronously during `init/1`, the exit propagates and the supervisor
  may restart the Watcher. Whether the Watcher's `:restart` option should be
  `:transient` or `:temporary` (to avoid thrashing) is not answered here. This
  is a supervision-tree design question outside the problem's scope but worth
  confirming before landing.
- **`rescue` arm removal**: the existing `rescue e` arm captures
  `Exception.message(e)` for exceptions raised (not exited) from
  `FileSystem.start_link/1`. The hybrid removes this arm. If the `FileSystem`
  library raises rather than exits on bad input in any version, that path is
  now unhandled. The proposal judges this acceptable because the library's
  documented contract uses return values and exits, not raises — but this
  assumption is not verified against the current pinned version.
- **Test coverage of the `{:DOWN, ...}` handler**: the acceptance criterion
  does not require a new test, but the handler is untested. Filing a follow-up
  test issue is recommended.

## Linked sub-problems / proposals

- `proposals/proposal-1.md` — Pattern-match on `FileSystem.start_link/1` return
  value only; minimal deletion, no new state, satisfies acceptance criterion but
  leaves runtime-crash gap.
- `proposals/proposal-2.md` — Extract `FileSystem` startup into a monitored
  helper process; OTP-compliant but adds helper-process complexity, an
  arbitrary timeout, and hard-to-test code paths.
- `proposals/proposal-3.md` — Introduce `Tau.Settings.FileSystemAdapter`
  behaviour; improves testability and extensibility but over-scoped for this
  problem; crash propagation path identical to Proposal 1.
- `proposals/proposal-4.md` — Move `FileSystem` startup to a monitored child;
  adds `handle_info({:DOWN, ...})` for runtime crashes; canonical OTP pattern;
  combined with Proposal 1's `maybe_start_watcher/1` body to form this hybrid.

## Revision history

- (revision 0 — initial)
