---
template_version: 1
template_name: problem
node_kind: leaf
depth: 1
parent: ../../problem.md
status: draft
---

# Problem: Settings.Watcher catches :exit from FileSystem.start_link/1

## Statement

`Tau.Settings.Watcher.maybe_start_watcher/1` wraps
`FileSystem.start_link/1` in a `try/rescue/catch` block that explicitly
catches `:exit` signals (line 81 — `catch :exit, reason`). OTP NN #7
(CLAUDE.md) states "MUST NOT `try/rescue` across process boundaries" and
"MUST NOT catch `:exit`". `FileSystem.start_link/1` crosses a process
boundary — it starts an external supervised process — so `:exit` signals
from it are OTP crash signals, not domain values. Catching them prevents
the supervisor from observing a real failure and gives the process a
false-normal state.

## Context

- `lib/tau/settings/watcher.ex:60-85` — `maybe_start_watcher/1`; the
  catch ladder runs: `try ... rescue e -> ... catch :exit, reason -> ...
  catch kind, reason -> ...`.
- The function's callers (lines 41-55) treat `{:ok, pid}` vs any other
  tuple as "healthy" vs "degraded". The degraded path emits telemetry
  and sets `watcher: nil` in state — this is the correct design for
  unavailable `FileSystem`.
- The legal failure cases `FileSystem.start_link/1` can return normally:
  `{:error, reason}` (e.g. `:no_dirs`, `:file_system_not_loaded`).
  These are matched explicitly by the `other ->` arm on line 75.
- `:exit` from `FileSystem.start_link/1` indicates a crash in the
  `FileSystem` supervision chain — a true OTP fault, not a soft
  degradation signal.
- `test/tau/settings/watcher_test.exs` exercises degraded-mode telemetry
  via `dirs: []` path (avoids invoking `FileSystem.start_link` at all);
  the `:exit` path has no test.

## Complecting hypothesis

The Watcher's soft-degradation handling is complected with OTP crash
propagation because both are routed through the same `catch` arm,
treating a supervisor-level exit as equivalent to a domain-level startup
failure.

## Decomposition strategy

(leaf — no further decomposition; proceed to proposals)

## Acceptance criterion

`maybe_start_watcher/1` no longer contains `catch :exit` (or any
`try/rescue/catch` that crosses the `FileSystem.start_link/1` call);
legitimate startup failures (`{:error, reason}`) are handled by
pattern-matching on the return value; and the degraded-mode telemetry
path (`watcher_degraded`) continues to fire under the existing test
conditions.

## Out of scope

- `Settings.Watcher` debounce logic or `relevant?/1` filtering.
- `Settings.Cache` reload trigger path.
- `Loader.merge/2` property tests (sibling problem).
- `Schema.to_known_module/1` control flow (sibling problem).
- Any changes to what constitutes a "relevant" file change event.

## Amendment log

- (none yet)
