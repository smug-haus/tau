# Refactor inventories

Working documents for the `Tau.Session` and `Tau.TUI.App` decomposition.
Read by subagents performing the extraction so the coordinator does not
need to load the full god modules into context. Source-of-truth function
tables produced by AST traversal + grep, not narrative.

- `inventory-session.md` — `lib/tau/session.ex` (5,208 LOC) function table,
  call graph, cluster candidates, FSM clause map, `data` field list,
  `try/rescue` sites.
- `inventory-tui-app.md` — `lib/tau/tui/app.ex` (1,508 LOC) function
  table, MVU model fields, dispatch table, cluster candidates.
- `conventions.md` — existing project conventions for sub-module
  organisation, `defstruct` usage, property-test layout, documentation
  style. New modules conform to these.

These files describe the codebase at the time of decomposition. They
become stale once the extraction lands. Do not read them as
documentation of the current state after merge.
