# Contributing to Tau

Thanks for considering a contribution. This file collects the rules that
live outside the code itself. Read [`CLAUDE.md`](./CLAUDE.md) first — its
non-negotiables and "What NOT to do" list are the spine of the project.
Anything here is in addition.

The backlog lives on GitHub issues. File one before writing code, reference
it from your commits (`Closes #N`), and link it from the PR.

## Dependencies

**BEAM ecosystem first.** Prefer Erlang/Elixir libraries and the OTP stdlib
over deps from outside the ecosystem (C NIFs, ports calling out to
non-BEAM runtimes, vendored binaries). Out-of-ecosystem deps require an
explicit, written **strong case** in the PR description that answers:

1. What specific capability is unavailable in the BEAM ecosystem?
2. Why is reimplementing it impractical (months of work, not an afternoon)?
3. What concrete, load-bearing value does the dep deliver?

This generalises the rule that already exists in `CLAUDE.md`'s "What NOT
to do" — no HTTP client besides `Finch`/`Mint`, no JSON library besides
`Jason`. Those entries are canonical; this section explains the principle
behind them so you can extend it correctly to new cases.

### The current dep set is the budget

Look at `mix.exs` before reaching for a new package. Tau already justifies:

- `jason` — JSON. The canonical choice. Don't add a faster parser.
- `finch` + `mint` + `castore` — HTTP. The canonical stack.
- `telemetry` + `telemetry_metrics` — observability. Use these, not
  `Logger`-only or homegrown counters.
- `phoenix_pubsub` — cross-process event fanout (non-negotiable #4).
- `file_system` — filesystem watcher (no good stdlib equivalent).
- `ex_json_schema` + `nimble_options` — schema and option validation.
- `optimus` — CLI argv parsing.
- `uniq` — ULIDs for sortable session/event ids.
- `ratatouille` — TUI (dev-only, optional).
- `aws_credentials` — Bedrock auth chain (optional).
- `burrito` — self-contained release packaging (release-only).

Test/dev tools (`mox`, `stream_data`, `bypass`, `briefly`, `dialyxir`,
`credo`, `excoveralls`, `ex_doc`) are scoped to those envs and held to the
same bar.

### The test for a new dep

Before you open the PR, answer these in writing:

- **Is the capability genuinely missing from OTP and the ecosystem?**
  Not "there's a nicer API for it" — actually missing.
- **Would reimplementing it be months of work for a worse result?**
  If you could write it in a weekend, write it in a weekend.
- **Is the value load-bearing for a feature users care about?**
  Convenience is not load-bearing.

If all three are yes, the dep is probably fine — argue the case in the PR
description. If any is no, drop the dep and use what's already in
`mix.exs` or the stdlib.

### Worked examples

**Yes — Exqlite + FTS5** (memory storage, see #67). FTS5 has no
production-grade equivalent in the BEAM ecosystem. Reimplementing
tokenisation, posting lists, and BM25 ranking is months of work for a
worse result. Hybrid keyword + semantic retrieval is load-bearing for the
memory subsystem.

**No — a faster JSON parser than Jason.** Jason is fine; the speedup
doesn't matter at our throughput. Adds a maintenance surface for nothing.

**No — a vector index dep at small scales.** At ~10k–50k vectors,
pure-Elixir brute-force cosine over ETS is sufficient. The dep adds
operational weight without the capability gap that FTS5 has.

### What this is NOT

- **Not a target dep count.** Tau is deliberately broader than minimal —
  every dep in `mix.exs` has a concrete reason. The discipline is
  "argued for in writing", not "small number".
- **Not a freeze.** Adding a dep with a strong case is fine. Saying yes
  is allowed; the override just has to be written down.
- **Not a hard ban on C NIFs.** The default is no, the override is a
  strong case.

## Workflow

1. Find or file the GitHub issue. Use the area labels listed in
   `CLAUDE.md` ("Workflow: GitHub issues are the backlog").
2. Make the change. Keep `mix format`, `mix credo --strict`, and
   `mix dialyzer` green.
3. Commit with `Closes #N` (or `Refs #N` for partial work).
4. Open a PR that lists the issues it closes and, for any
   out-of-ecosystem dep, includes the strong case described above.

For changes that touch a behaviour contract, the supervision tree, or a
public struct's hidden contract, file an ADR in `docs/adr/` — see
`docs/adr/README.md`.
