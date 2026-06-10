---
template_version: 1
template_name: solution
parent_problem: problem.md
node_kind: leaf
synthesised_from: [proposals/proposal-1.md]
selection_method: single
revision: 0
---

# Solution: Tagged-result return for expose_tau_context?/0

## Recommendation

Replace `expose_tau_context?/0`'s `rescue`/`catch` fallback with a renamed
`fetch_expose_tau_context/0` that returns `{:ok, boolean()} | {:error,
:cache_unavailable}`. Update `maybe_start_tau_context/1` to pattern-match
explicitly on all three outcomes: start TauContext on `{:ok, true}`, skip on
`{:ok, false}`, and on `{:error, :cache_unavailable}` emit a telemetry event
and skip (fail-closed). This is the smallest change that fully satisfies the
acceptance criterion within the declared scope, does not require topology
verification, and uses an established Elixir convention for failable reads.

## Selected from

- **Chosen:** `proposals/proposal-1.md`
- **Why chosen:** Proposal 1 is the only candidate that (a) satisfies the
  acceptance criterion without going out of scope and (b) does not introduce
  disproportionate failure risk. Proposal 4 is explicitly out of scope
  (requires modifying `SettingsCache`). Proposal 2 is in-scope code-wise but
  carries an unresolved crash-loop risk: if SettingsCache is transiently absent
  during supervised startup the Dispatcher will crash repeatedly, potentially
  exhausting restart intensity and killing the subsystem for the session — a
  harder failure than the one being fixed, and one that cannot be assessed
  without topology verification the problem statement excludes. Proposal 3
  introduces a new module and a `:not_set` sentinel whose `:configured` vs
  `:default` distinction provides no value at the current call site and adds
  complexity a tagged tuple already handles. Proposal 1's tagged-result form
  directly decomplects crash containment from flag retrieval, is reversible
  (all changes are in private functions), and costs ~30 lines confined to
  `dispatcher.ex`.

## Scoring table

| # | Fit | Decomplecting depth | Migration cost | Risk | Reversibility |
|---|-----|---------------------|----------------|------|---------------|
| 1 | Yes | Substantial | Low | Low | Easy |
| 2 | Yes | Deep | Low | High | Easy |
| 3 | Yes | Substantial | Low–Medium | Low | Easy |
| 4 | Partial (out-of-scope) | Deep | Medium | Low–Medium | Easy |

Proposal 2 scores Deep on decomplecting depth but High on risk due to the
crash-loop concern; per the select protocol, reversibility over irreversibility
and avoidance of High-risk candidates tips the decision to Proposal 1.
Proposal 3 matches Proposal 1 on all axes but adds a new module with no
incremental benefit at the current call site — a premature generalisation.

## What changes

- `lib/tau/coding_agent/dispatcher.ex`:
  - Rename `expose_tau_context?/0` → `fetch_expose_tau_context/0`.
  - Change return type from `boolean()` to `{:ok, boolean()} | {:error, :cache_unavailable}`.
  - The `rescue`/`catch` ladder returns `{:error, :cache_unavailable}` instead of `%{}`.
  - Successful path returns `{:ok, value}` where `value` is the resolved boolean.
  - Rewrite `maybe_start_tau_context/1` to pattern-match on all three cases:
    - `{:ok, true}` → call `do_start_tau_context/1` (extracted helper).
    - `{:ok, false}` → return state unchanged.
    - `{:error, :cache_unavailable}` → emit `[:tau, :coding_agent, :tau_context, :settings_unavailable]` telemetry and return state unchanged.
  - Extract the MCP-server startup body from `maybe_start_tau_context/1` into a
    private `do_start_tau_context/1` (no logic change; separation is mechanical).

## What does not change

- `lib/tau/settings/cache.ex` — `SettingsCache` is not modified.
- `Tau.CodingAgent.Supervisor` and `lib/tau/application.ex` — supervision tree
  topology and restart strategy are not touched.
- External callers of `maybe_start_tau_context/1` — both functions are private;
  no public API change.
- Telemetry event name convention — the `:settings_unavailable` event follows
  existing `[:tau, :coding_agent, ...]` namespace.
- The `:safe_start`/`:safe_cancel` wrappers — excluded per problem scope.

## Migration sketch

All changes are in a single private call chain, so the migration is a single
atomic commit: rename `expose_tau_context?/0` to `fetch_expose_tau_context/0`,
update its return shape, rewrite `maybe_start_tau_context/1` to match on the
new return, extract `do_start_tau_context/1`. Update tests to add a case for
SettingsCache raising (expects state unchanged + telemetry fired). No staged
rollout required; no callers outside `dispatcher.ex` are affected.

## Open questions

1. **SettingsCache failure mode**: Proposal 1 notes with medium confidence that
   `SettingsCache.get/0` actually raises (rather than returning `{:error, _}`)
   when the process is absent. If it returns an error tuple, the `rescue`/`catch`
   arms are dead code and a future refactor should remove them. The implementer
   should verify by reading `lib/tau/settings/cache.ex` (read-only; not modified
   here) and document the finding in the PR.
2. **Key type normalisation**: the existing code pattern-matches both atom key
   (`:expose_tau_context`) and string key (`"expose_tau_context"`) from the
   settings map. This is a pre-existing issue; the solution preserves it. If
   settings normalisation is added later (e.g. via `Tau.CodingAgent.Settings`),
   the dual-key fallback can be dropped.
3. **Telemetry consumer**: the `:settings_unavailable` event is emitted but
   there is currently no documented consumer. If no consumer reads it, the
   observability gain is latent. This is an open question for the operator
   instrumentation story, not a blocker for this fix.

## Linked sub-problems / proposals

- `proposals/proposal-1.md` — Tagged-result return; `fetch_expose_tau_context/0` returning `{:ok, bool} | {:error, :cache_unavailable}`
- `proposals/proposal-2.md` — Eliminate rescue entirely; propagate crash to Dispatcher supervisor (High risk without topology verification)
- `proposals/proposal-3.md` — FeatureFlag struct encoding origin alongside value (premature generalisation for a private, single-use predicate)
- `proposals/proposal-4.md` — Push flag resolution into SettingsCache via `get_flag/2` API (out of scope per problem statement)

## Revision history

- (revision 0 — initial)
