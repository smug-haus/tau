# ADR-0007: Compaction summaries are pinned across re-compaction

- **Status:** Accepted
- **Date:** 2026-04-30
- **Deciders:** @smug-haus
- **Related:**
  - Issue: #56
  - Code: `lib/tau/compactor/summarize_tail.ex`
  - Prior: ADR-0005 (`metadata.role :system` for memory + skill
    pins)

## Context

`Tau.Compactor.SummarizeTail.pinned?/1` matches only
`metadata.role :system` (memory cascade + skills). The synthetic
summary message produced by an earlier compaction carries
`metadata.role :compaction_summary` and falls into the
non-pinned branch. So the next compaction folds the previous
summary into its conversational split and re-summarises a
summary — geometric fidelity loss across rounds.

Three options came up (#56):

1. **Pin compaction summaries verbatim** — every prior summary
   stays at the head of the conv list. Stable but
   pinned-region grows unboundedly across long sessions.
2. **Drop the old summary before re-summarising** — fold its
   content into the new summarisation prompt as
   "previous summary: ..." and replace. Single bounded summary,
   no chain.
3. **Cap the summary chain depth** — keep up to N summaries.

## Decision

Pick **(1)** for now: extend `pinned?/1` to match
`metadata.role :compaction_summary` in addition to
`:system`. Compaction summaries survive every subsequent
compaction unchanged.

The pinned-region growth is bounded in practice: a session that
triggers compaction every 50 messages (default threshold)
accumulates one summary per ~50-message window. A 1000-turn
session ends up with ~20 summaries, each a few hundred tokens —
manageable for any modern context window.

When measurements show otherwise (a real session running into
context pressure from accumulated summaries), revisit with a new
ADR — option (2) is the natural follow-up.

## Consequences

- Older summaries no longer get re-summarised. Information
  density across the long-history tail is preserved.
- The pinned region can grow over multi-hour sessions. Bounded
  by compaction threshold × session lifetime; not currently
  measured.
- Trivial code change: one extra clause on `pinned?/1`.
- Tests pin the new behaviour; the existing
  "summary-of-summary" anti-pattern would now be caught by a
  `Enum.count_summaries(post_compact)` check.

## Alternatives considered

- **Option (2): drop and re-fold.** Cleaner steady-state size
  but requires an extra `summarise/2` round-trip with the prior
  summary inlined, and there's no obvious win — the fresh
  summary is an LLM-generated paraphrase of a paraphrase, which
  is exactly the lossiness option (1) avoids.
- **Option (3): cap depth.** Adds a parameter to think about
  ahead of time, with no measurement to guide the value.

## Notes

`Tau.Memory.User` messages with `metadata.role :system` are
already pinned by the existing clause; they continue to work
unchanged. The new clause is purely additive.

If a future compactor strategy wants to redefine
"don't summarise me," it should also use
`metadata.role :compaction_summary` (or a successor convention)
and update this ADR — or supersede it.
