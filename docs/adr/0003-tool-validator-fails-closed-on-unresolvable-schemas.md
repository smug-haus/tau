# ADR-0003: `Tau.Tool.Validator` fails closed on unresolvable schemas

- **Status:** Accepted
- **Date:** 2026-04-30
- **Deciders:** @smug-haus
- **Related:**
  - Issue: #50 (the security finding this resolves)
  - Code: `lib/tau/tool/validator.ex`, `lib/tau/session.ex`
  - Prior: ADR-0001

## Context

`Tau.Tool.Validator.validate/2` resolves a tool's `parameters/0`
JSON Schema via `ExJsonSchema.Schema.resolve/1` and validates the
model-supplied args against it. When `resolve/1` raises (malformed
schema, unsupported draft, unresolvable `$ref`, …), the validator
has to choose between:

1. **Fail closed.** Reject the call with an error, the model gets
   an `is_error: true` `ToolResult` and can self-correct.
2. **Fail open (bypass).** Accept whatever the model passes and
   forward to `mod.execute/2`.

The original implementation chose (2) and additionally cached the
unresolvable-schema result in `:persistent_term`, so the bypass
became permanent for the lifetime of the BEAM. For built-in tools
whose schemas we control, this is mostly cosmetic (we'd never ship
a malformed schema). For MCP-derived tools whose schemas come from
third-party servers, it's a security regression: a hostile or
buggy MCP server can ship a schema fragment that fails to resolve
and that tool then accepts arbitrary input — forever.

## Decision

`Tau.Tool.Validator.validate/2` fails closed: when the schema
can't be resolved, it returns
`{:error, [{"schema unresolvable: <reason>", "#"}]}` and the
session synthesises an `is_error: true` `ToolResult`. The tool is
effectively disabled until either:

- the tool re-registers with a valid schema, OR
- a `Tau.Tool.Validator.invalidate(mod)` call evicts the cached
  result (also new in this ADR).

Cache policy: only successful `{:ok, resolved}` results are
written to `:persistent_term`. Failures are emitted on the
`[:tau, :tool, :validate, :schema_error]` telemetry event but
**not cached** — the next call re-attempts resolution. This costs
one resolution per call for genuinely-broken tools (rare and
self-limiting since they never execute), but means a tool that
gains a valid schema later doesn't need a manual cache flush.

## Consequences

- MCP servers cannot weaponise broken schemas as a validation
  bypass.
- Tools with malformed schemas surface immediately as
  user-visible errors instead of silently accepting anything.
- One resolution attempt per call is paid by broken tools (which
  the model will stop calling once it sees the error). Healthy
  tools continue to use the cache and pay zero per-call cost.
- `Tau.Tool.Validator.invalidate/1` is a small public API
  addition; useful for hot-reloading a tool after fixing its
  schema in-process.

## Alternatives considered

- **Bounded permissive fallback.** When resolution fails, accept
  only valid JSON object values (`is_map(args)`). Less abrupt
  for an MCP server with a typo in their schema, but still
  permits arbitrary keys/values within the object — which is
  exactly the surface a malicious tool would abuse. The line
  "must be a JSON object" is too weak to be useful as a
  security boundary.
- **Cache the failure with TTL.** Adds time-keeping logic and
  doesn't actually help a server that re-registers with a
  corrected schema mid-TTL. Simpler not to cache failures at
  all.
- **Keep failing open.** The original behaviour. Convenient for
  development, dangerous in production once any third-party
  MCP server is in the loop.

## Notes

The session's call site (`Tau.Session.run_tool/4`) was already
shaped to handle `{:error, errors}` — it formats and synthesises
the `is_error: true` `ToolResult`. The only change is in the
validator's error path.
