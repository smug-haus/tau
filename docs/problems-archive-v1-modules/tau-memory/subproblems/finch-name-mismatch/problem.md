---
template_version: 1
template_name: problem
node_kind: leaf
depth: 1
parent: ../../problem.md
status: draft
---

# Problem: EmbeddingWorker defaults to a Finch pool name that does not exist

## Statement

`Tau.Memory.EmbeddingWorker.call_embedding_api/3` reads the Finch pool name via
`Application.get_env(:tau, :finch_name, Tau.Finch)` (line 106). The application
supervision tree registers the pool as `Tau.Providers.Finch` (application.ex:78).
No deployment sets `:tau, :finch_name`. As a result, every `Finch.request/3`
call resolves a name that has no registered process, crashes the Task with
`:noproc`, and prevents any embedding from completing under the default
configuration shipped in the repository.

## Context

- `lib/tau/memory/embedding_worker.ex:106` — the defective default: `Application.get_env(:tau, :finch_name, Tau.Finch)`.
- `lib/tau/application.ex:78` — `{Finch, name: Tau.Providers.Finch}` — the one and only Finch pool.
- No application config file (`config/config.exs`, `config/runtime.exs`) sets `:tau, :finch_name`, so the default is always exercised in production.
- The fix is a single-atom change at the default site; alternatively, a named constant shared between `application.ex` and `embedding_worker.ex` eliminates future drift.

## Complecting hypothesis

- The pool name at the call-site is complected with the name declared in the supervision tree because no shared constant binds them; the two sites can drift without a compile-time error.

## Decomposition strategy

(leaf — no further decomposition; proceed to proposals)

## Acceptance criterion

`Finch.request/3` in `EmbeddingWorker` resolves the pool name that `Tau.Application`
registers, so embedding HTTP calls succeed in a standard `mix run` / release
environment without any extra application config.

## Out of scope

- Observability of stuck entries (covered by `pending-rot-observability`).
- Task crash propagation without callback (covered by `silent-failure-propagation`).
- Retry / recovery of already-stuck entries (covered by `retry-recovery-path`).

## Amendment log

- (none yet)
