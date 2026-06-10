---
template_version: 1
template_name: problem
node_kind: leaf
depth: 1
parent: ../../problem.md
status: draft
---

# Problem: error-swallowing rescues in CLI MCP and Extensions handlers

## Statement

`Tau.CLI.Extensions.safe_list/0`, `safe_reload/0`, `Tau.CLI.MCP.safe_list/0`,
and `safe_reload/0` wrap calls to supervised processes in `rescue _ -> []` /
`catch :exit, _ -> []` blocks, converting any process crash, noproc exit, or
runtime error into an empty-result or silent error. A user running `tau
extensions list` when the `Extensions.Loader` is down sees "(no extensions
loaded)" rather than an error; `tau mcp reload` failing silently returns 0
instead of a non-zero exit. The supervision-tree failure mode is invisible.

## Context

- `lib/tau/cli/extensions.ex:67–73` — `safe_list/0`: `rescue _ -> []` and
  `catch :exit, _ -> []` around `Tau.Extensions.Loader.list/0`.
- `lib/tau/cli/extensions.ex:75–81` — `safe_reload/0`: `rescue e -> {:error, ...}`
  and `catch :exit, reason -> {:error, reason}` around
  `Tau.Extensions.Loader.reload_all/0`.
- `lib/tau/cli/mcp.ex:98–104` — `safe_list/0`: identical pattern around
  `Tau.MCP.Reconciler.list/0`.
- `lib/tau/cli/mcp.ex:106–112` — `safe_reload/0`: identical pattern around
  `Tau.MCP.Reconciler.reload/0`.
- OTP non-negotiable #7: "Let it crash; supervise; restart. MUST NOT
  `try/rescue` across process boundaries. MUST NOT catch `:exit`."
- `Tau.Extensions.Loader` and `Tau.MCP.Reconciler` are both supervised
  GenServers; a `:noproc` exit from them is a supervision-tree signal that
  should surface to the operator, not be swallowed.

## Complecting hypothesis

- Error reporting is complected with data retrieval: the same function that
  fetches the data also decides whether a process crash constitutes "no data"
  or an error, removing the operator's ability to distinguish between "nothing
  is configured" and "the subsystem is down".

## Decomposition strategy

(leaf — no further decomposition; proceed to proposals)

## Acceptance criterion

`tau extensions list`, `tau extensions reload`, `tau mcp list`, and
`tau mcp reload` return a non-zero exit code and print a diagnostically useful
error message to stderr whenever the underlying supervised process is
unavailable (`:noproc`, process exit, or an unexpected exception), rather than
printing an empty-result message and returning 0.

## Out of scope

- `safe_to_atom/1` in `Tau.CLI.Config` (different file, different concern —
  belongs to the reflective-dispatch sub-problem)
- `validate/1` rescue in `Tau.CLI.Config` and `Tau.CLI.Init` (different
  failure mode — those wrap library calls, not supervised processes)
- Run-loop rescue/catch in `drain_run_loop/2` (owned by run-loop-raw-receive)
- Any extension loader internals beyond the CLI shim boundary

## Amendment log

- (none yet)
