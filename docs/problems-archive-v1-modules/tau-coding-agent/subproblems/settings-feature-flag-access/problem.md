---
template_version: 1
template_name: problem
node_kind: leaf
depth: 1
parent: ../../problem.md
status: draft
---

# Problem: expose_tau_context? silently conflates cache failure with unconfigured feature

## Statement

`Tau.CodingAgent.Dispatcher.expose_tau_context?/0`
(`lib/tau/coding_agent/dispatcher.ex:384–399`) wraps `SettingsCache.get/0` in
`rescue` + `catch`, falling back to `%{}` on any error. The fallback is
identical to the fallback for a cache that returns an empty settings map (i.e.
the feature is genuinely unconfigured). When the cache is unavailable or
crashes, the function silently returns `true` — enabling `TauContext` even
though the system state is unknown — rather than propagating or flagging the
failure.

## Context

- `lib/tau/coding_agent/dispatcher.ex:344–372` — `maybe_start_tau_context/1`
  calls `expose_tau_context?/0` and, on `true`, starts a per-run MCP server;
  a failure at startup is handled by telemetry + graceful degradation.
- `lib/tau/coding_agent/dispatcher.ex:384–399` — the rescue/catch ladder:
  any exception or throw from `SettingsCache.get/0` produces `%{}`, which
  the subsequent pattern match treats as "expose_tau_context: true (default)".
- `lib/tau/settings/cache.ex` (not in scope to modify) — `SettingsCache.get/0`
  can crash if the cache process is not started or its ETS table is absent
  during test isolation or mis-sequenced startup.
- SPEC-CODING-AGENT §4: the `expose_tau_context` setting controls whether a
  per-run MCP server is started. Defaulting to `true` on cache failure starts
  the server in an environment that may have no settings context at all.

## Complecting hypothesis

Feature-flag retrieval is complected with crash containment: the function
cannot distinguish "SettingsCache not yet started" (a legitimate transient
state during supervised startup or test isolation) from "the setting is absent"
(feature defaults to on), and both are silently mapped to the same `true`
return.

## Decomposition strategy

(leaf — no further decomposition; proceed to proposals)

## Acceptance criterion

`expose_tau_context?/0` returns a value that the caller can use to distinguish
"setting is on", "setting is off", and "cache unavailable"; callers in
`maybe_start_tau_context/1` handle each case explicitly without conflating
cache failures with deliberate configuration.

## Out of scope

- Changes to `SettingsCache` itself.
- The `safe_start/3` / `safe_cancel/2` wrappers in `dispatcher.ex`
  (sibling sub-problem `tool-impl-rescue-ladders` owns `tools.ex` rescues;
  `safe_start`/`safe_cancel` are adapter-boundary guards excluded from root
  out-of-scope).
- Retry or supervision policy for the settings cache.

## Amendment log

- (none yet)
