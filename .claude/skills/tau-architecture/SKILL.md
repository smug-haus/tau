---
name: tau-architecture
description: >
  Use when about to add or modify a behaviour callback, the supervision
  tree, or any public struct's hidden contract; or when needing rationale
  for the OTP non-negotiables; or when reasoning about worktree isolation
  and absolute-path leaks.
---

# tau-architecture — behaviours, style, worktree leaks

## §1 Behaviour reading order

Read in this order to understand the system from the inside out:

1. **`Tau.Tool`** — single-call tool contract; what `Read`, `Write`,
   `Edit`, `Bash` implement.
2. **`Tau.Provider`** — streaming LLM provider; emits
   `Tau.Provider.Event` items.
3. **`Tau.Hook`** — observation/intervention points around the loop.
4. **`Tau.Persistence`** — append-only event store (default: JSONL).
5. **`Tau.MCP.Transport`** — MCP wire protocol (stdio / SSE / HTTP).
6. **`Tau.Compactor`** — turn-history summarisation; pluggable strategy.
7. **`Tau.Extension`** — DSL host that registers tools / hooks / skills
   under one namespace.

Behaviours are the entry points. The `Tau.Permissions.Matcher` behaviour
is also worth a read once `Tau.Tool` is internalised — it gates tool
calls.

## §2 Style invariants

- **Licence:** Apache-2.0 (`LICENSE`).
- **Formatter:** `mix format` enforced; line length 100
  (`.formatter.exs`).
- **Static analysis:** Credo strict (`.credo.exs` for relaxations).
- **Docs:** `@moduledoc` on every public module; `@spec` on every public
  function.
- **Comments:** only when documenting a non-obvious invariant. Don't
  paraphrase the code.
- **Naming:** function names = verbs; module names = nouns; behaviours =
  role nouns (`Tau.Tool`, not `Tau.IExecuteTools`).

## §3 Worktree isolation — what it does and doesn't isolate

`isolation: "worktree"` on a subagent dispatch creates a fresh git
worktree on a fresh branch and runs the agent's CWD there. This
**isolates**:

- the working tree's tracked files (relative paths inside the agent's
  CWD),
- `HEAD`, the active branch, and any commits the agent makes,
- `git checkout` / `git switch` / `git reset` operations the agent runs.

It does **not** isolate:

- file-system writes via **absolute paths**. A `Write` /
  `Edit` to `/home/user/tau/lib/...` bypasses the worktree CWD entirely
  and lands on the **parent** tree, which is on its own branch
  (typically `main`).
- side effects outside git (caches, `~/.mix`, etc.).

**Consequence:** two parallel isolated agents on different branches
can still clobber each other if they write absolute paths. Symptoms:
branches end up at HEAD with no commits; edits land on the wrong branch;
the parent working tree is left half-applied.

**Mitigation:** brief subagents to use **relative paths only** for
`Read` / `Edit` / `Write`. As a coordinator, periodically run `git
checkout main && git reset --hard origin/main` between dispatches in
the parent worktree to discard any leaked edits.

**Single-agent foreground work** (no parallel siblings) does not need
isolation — the parent and child can't race a single working tree.

## §4 Architectural decisions

The non-negotiables (`.claude/rules/otp-non-negotiables.md`) tell you
what's _forbidden_. ADRs in `docs/adr/` tell you what was _chosen_, and
why a future change would need fresh justification. Read
`docs/adr/README.md` first; index lists ADR-0001 through ADR-0017 at
the time of writing. The `tau-adr` skill covers when and how to add a
new one.
