---
template_version: 1
template_name: validation
parent_solution: solution.md
parent_problem: problem.md
toulmin_complete: true
falsification_attempted: true
falsification_outcome: withstood
revision_triggered: none
---

# Validation: Shared config module binds the Finch pool name at both sites

## Overview

The solution asserts four checkable propositions: (1) the defect is real
and unambiguous; (2) a new `Tau.Providers.Config` module with `finch_name/0`
makes the two-site binding compile-time-visible; (3) the `Application.get_env`
escape hatch is preserved; (4) no other callers or test files require
updating. Each is validated below via Toulmin with six components, followed
by a named falsification attempt. All four claims withstood; no revision is
required.

---

## Toulmin per claim

The MITRE empirical study on Toulmin formalism found that "participants
found it difficult to generate Toulmin structures, and their structures
varied greatly even though they started with the same content"
(https://www.mitre.org/news-insights/publication/empirical-evaluation-structured-argumentation-using-toulmin-argument).
This template enforces all six components explicitly with prompts to
counter that variance.

---

### Claim 1: The default atom `Tau.Finch` in `EmbeddingWorker` does not name any registered Finch pool, causing every embedding HTTP call to crash with `:noproc`.

- **Claim (C):** The default atom `Tau.Finch` in `EmbeddingWorker` does not
  name any registered Finch pool, causing every embedding HTTP call to crash
  with `:noproc`.
- **Grounds (G):**
  - `lib/tau/memory/embedding_worker.ex:106` — `Application.get_env(:tau,
    :finch_name, Tau.Finch)`: the default is the atom `Tau.Finch`.
  - `lib/tau/application.ex:78` — `{Finch, name: Tau.Providers.Finch}`: the
    sole pool registration uses the atom `Tau.Providers.Finch`.
  - `grep -rn "finch_name" config/` returns empty output: no application
    config file overrides `:tau, :finch_name`. The default is always
    exercised.
  - `grep -rn "Tau.Finch\b" lib/ test/` returns exactly one hit
    (`embedding_worker.ex:106`): no other code registers or supervises a
    pool named `Tau.Finch`.
- **Warrant (W):** `Finch.request/3` resolves the pool name via a process
  registry lookup. An atom that has never been registered as a `Finch`
  child process cannot be found; the GenServer call raises `{:noproc,
  ...}` and crashes the calling process. The OTP registry guarantee is
  deterministic: absent registration equals absent process.
- **Qualifier (Q):** This claim holds in any environment that: (a) does not
  set `Application.put_env(:tau, :finch_name, Tau.Providers.Finch)` at
  runtime before `EmbeddingWorker` calls `call_embedding_api/3`, and (b) does
  not start a second Finch pool named `Tau.Finch` through some other path.
  Neither condition holds in the standard `mix run` or release environment
  per the config-file audit above.
- **Rebuttal (R):** If a test helper or a deployment harness sets `:tau,
  :finch_name` before the worker starts, the default is bypassed and the bug
  is masked. However, the problem statement and the config-file audit confirm
  no such override exists in the repository; the default is always active.
- **Backing (B):** `Finch` source (hexdocs.pm/finch): `Finch.request/3`
  calls `Finch.Pool.async_request/5` which looks up the pool by name via
  `Finch.Registry`; an unregistered name returns `{:error, %Mint.TransportError{reason: :noproc}}` or raises, depending on version.
  OTP non-negotiable §1 (`otp-non-negotiables.md`): every stateful subsystem
  runs as a supervised process — a missing supervision entry means the
  process does not exist.

#### Falsification attempt for claim 1

- **Strategy:** Dependency check — verify the assumed codebase state
  (the two atoms differ; no config override exists; no second pool is
  registered).
- **Attempt:** Searched `lib/` and `test/` for `Tau.Finch\b` (non-Providers
  variant); found exactly one hit at `embedding_worker.ex:106`. Searched
  `config/` for `finch_name`; found no hits. Searched `lib/` for
  `{Finch, name:` patterns; found exactly one registration at
  `application.ex:78` using `Tau.Providers.Finch`.
- **Outcome:** Withstood. The dependency state assumed by the claim is
  confirmed; no second pool, no config override, atoms provably differ.
- **Action:** None required.

---

### Claim 2: Introducing `Tau.Providers.Config.finch_name/0` and updating both call sites makes the binding compile-time-visible, eliminating future silent drift.

- **Claim (C):** Introducing `Tau.Providers.Config.finch_name/0` and
  updating both call sites makes the binding compile-time-visible,
  eliminating future silent drift.
- **Grounds (G):**
  - `lib/tau/providers/` directory currently contains no `config.ex`; the
    new module does not conflict with any existing file.
  - `lib/tau/application.ex:78` — the proposed change: `{Finch, name:
    Tau.Providers.Config.finch_name()}`. This is a normal function call
    evaluated at supervision-tree startup; the result is the atom
    `Tau.Providers.Finch`.
  - `lib/tau/memory/embedding_worker.ex:106` — the proposed change:
    `Application.get_env(:tau, :finch_name,
    Tau.Providers.Config.finch_name())`. The default now derives from the
    same function.
  - The `@finch_name Tau.Providers.Finch` module attribute in
    `Tau.Providers.Config` is a compile-time constant; renaming the pool
    requires changing exactly one line; both sites recompile automatically
    because they call `finch_name/0` which is inlined by the BEAM for a
    zero-arity pure function.
- **Warrant (W):** A single authoritative constant consumed at all sites is
  the structural definition of eliminating drift: there is no longer a
  second independent literal that could diverge. Rich Hickey's "simplicity
  matters" principle: complecting two pieces of information (pool name at
  registration; pool name at call) by replication introduces accidental
  complexity; binding them to a shared name removes the complecting. The
  module attribute form ensures the constant is evaluated once and checked
  by the compiler.
- **Qualifier (Q):** "Compile-time-visible" holds for future renames that go
  through `Tau.Providers.Config.finch_name/0`. A developer who bypasses
  the accessor and writes a new bare atom literal at a new call site
  reintroduces drift. The claim is scoped to the two sites named in the
  solution; it cannot prevent unbounded future misuse.
- **Rebuttal (R):** `Application.get_env/3` is evaluated at runtime, not
  compile time; the `default` argument (now `Tau.Providers.Config.finch_name()`)
  is also evaluated at runtime. The "compile-time-visible" language in the
  solution is slightly imprecise: it means "a single source of truth a
  developer must consciously override, not a second atom literal that can
  silently diverge." The safety property holds; the precision of the label
  is slightly weaker than advertised.
- **Backing (B):** OTP non-negotiable §2 (`otp-non-negotiables.md`):
  extensibility seams must be behaviours, and by extension single-source
  constants must be shared, not replicated. The problem's complecting
  hypothesis (`problem.md §Complecting hypothesis`) identifies exactly this
  as the root structure to eliminate.

#### Falsification attempt for claim 2

- **Strategy:** Counter-example construction — construct a scenario where
  the proposed change does NOT eliminate drift.
- **Attempt:** Consider a future developer adding a third Finch consumer
  (e.g., a new `lib/tau/tools/http_tool.ex`) and writing
  `Finch.request(req, Tau.Providers.Finch)` as a bare atom. This new site
  drifts immediately. Now consider a developer renaming the pool: they
  update `Tau.Providers.Config.finch_name/0`; the two updated sites are
  correct; the new bare-atom site is silently wrong. This is a valid
  counter-example — BUT it is outside the scope of the claim. The claim is
  "eliminates future silent drift [at the two named call sites]"; the
  solution's Qualifier field admits this scope. The counter-example therefore
  partially falsifies an overly broad reading of the claim but does not
  falsify the scoped reading. The existing callers `mcp/transport/http.ex`,
  `mcp/transport/sse.ex`, `providers/shared/finch_stream.ex`,
  `providers/copilot/auth.ex` already use the bare atom `Tau.Providers.Finch`
  and are NOT updated by this solution — consistent with the solution's
  stated scope (those sites use the correct atom; only `embedding_worker.ex`
  used the wrong one).
- **Outcome:** Partially falsified — the claim that the solution eliminates
  "future drift" must be scoped to the two named sites and to renames
  propagated through `finch_name/0`. Bare-atom consumers outside the two
  named sites are not protected.
- **Action:** Narrow qualifier (see above); no solution revision required.
  The acceptance criterion (`problem.md`) requires only that `Finch.request/3`
  in `EmbeddingWorker` resolves the registered pool; the broader drift-proof
  property is a quality-of-life benefit, not a criterion.

---

### Claim 3: The `Application.get_env/3` runtime-override escape hatch is preserved for operators who need a custom pool.

- **Claim (C):** The `Application.get_env/3` runtime-override escape hatch
  is preserved for operators who need a custom pool.
- **Grounds (G):**
  - `lib/tau/memory/embedding_worker.ex:106` — the proposed form:
    `Application.get_env(:tau, :finch_name, Tau.Providers.Config.finch_name())`.
    The only change is to the `default` argument; the `Application.get_env/3`
    call itself is retained verbatim.
  - The solution's "What does not change" section explicitly states: "The
    `Application.get_env/3` lookup in `EmbeddingWorker` — the
    runtime-override escape hatch is preserved."
- **Warrant (W):** If the call form `Application.get_env(:tau, :finch_name,
  <default>)` is retained, any runtime-configured value of `:tau, :finch_name`
  still overrides the default. The `default` argument is evaluated only when
  the key is absent from the application environment. The operator's
  `Application.put_env(:tau, :finch_name, MyPool)` call still wins.
- **Qualifier (Q):** Universal within the `EmbeddingWorker` code path; no
  conditions under which this claim fails given the stated code change.
- **Rebuttal (R):** None. `Application.get_env/3` semantics are stable
  across Elixir 1.x and OTP 25+; the default-argument evaluation behaviour
  is not subject to version variation.
- **Backing (B):** Elixir 1.18 documentation for `Application.get_env/3`
  (hexdocs.pm/elixir/Application.html#get_env/3): "Returns the value for
  key in app's environment. If the configuration parameter does not exist,
  the function returns the default value."

#### Falsification attempt for claim 3

- **Strategy:** Type-level check — verify the proposed call signature is
  compatible with `Application.get_env/3` contract.
- **Attempt:** `Application.get_env(app, key, default)` — the `default`
  parameter is `any()`; `Tau.Providers.Config.finch_name()` returns an atom;
  atoms satisfy `any()`. No type error. The key `:finch_name` is an atom;
  the app `:tau` is an atom. Call signature is fully compatible.
- **Outcome:** Withstood. The escape hatch is structurally preserved; no
  type or semantic incompatibility introduced.
- **Action:** None required.

---

### Claim 4: No other files — callers of `EmbeddingWorker.embed/N`, tests that mock or reference the Finch name, and other supervision tree entries — require updating.

- **Claim (C):** No other files — callers of `EmbeddingWorker.embed/N`,
  tests that mock or reference the Finch name, and other supervision tree
  entries — require updating.
- **Grounds (G):**
  - `grep -rn "Tau.Finch\b" lib/ test/` — exactly one hit
    (`embedding_worker.ex:106`); no test file references `Tau.Finch`.
  - `grep -rn "finch_name" test/` — no hits; no test mocks the pool name.
  - `grep -rn "Tau.Providers.Finch" lib/` — six hits: `application.ex:78`,
    `mcp/transport/http.ex:28`, `mcp/transport/sse.ex:36`, `sse.ex:66`,
    `providers/shared/finch_stream.ex:76`, `providers/copilot/auth.ex:132`.
    All six already use the correct atom; none is the `EmbeddingWorker`
    default. None require updating.
  - `lib/tau/providers/config.ex` does not yet exist; the new module
    introduces no rename of existing identifiers.
- **Warrant (W):** The new `Tau.Providers.Config` module is a pure accessor
  with no side effects; it adds a new name to the namespace but aliases no
  existing name. Therefore its introduction cannot break any existing module
  that does not import it. Only the two sites that explicitly reference the
  shared constant need to change.
- **Qualifier (Q):** This claim holds assuming the codebase search is
  exhaustive (all files under `lib/` and `test/`). It does not extend to
  future files or to out-of-repo consumers.
- **Rebuttal (R):** If a test file uses `Application.put_env(:tau,
  :finch_name, ...)` as test setup, it would be in scope — but the search
  confirms no such test exists. If `EmbeddingWorker` has additional arities
  of `embed/N` that pass the pool name differently, those would need
  inspection. However, the defect is isolated to the one `get_env` default
  in `call_embedding_api/3`.
- **Backing (B):** The solution's "What does not change" section. Also: OTP
  non-negotiable §8 (`otp-non-negotiables.md`) — pure functions are the
  default; `finch_name/0` is a pure zero-arity accessor, so its introduction
  has no side effects on the supervision tree or process registry.

#### Falsification attempt for claim 4

- **Strategy:** Dependency check — verify the assumed codebase state (no
  tests reference `Tau.Finch`; all other `Tau.Providers.Finch` callers are
  already correct).
- **Attempt:** Ran `grep -rn "Tau.Finch\b"` and `grep -rn "finch_name"` over
  `lib/` and `test/`. `Tau.Finch\b` appears once (`embedding_worker.ex:106`).
  `finch_name` appears once (`embedding_worker.ex:106`). All other Finch
  consumers already reference `Tau.Providers.Finch` directly and do not use
  the `Application.get_env` indirection.
- **Outcome:** Withstood. The dependency assumption is correct; no additional
  files need modification.
- **Action:** None required.

---

## Cross-claim consistency

Claims 1–4 are internally consistent. Claim 1 establishes the defect;
Claim 2 establishes that the proposed fix closes it structurally; Claim 3
establishes that an existing safety valve is preserved; Claim 4 establishes
that the fix is surgical. No claim contradicts another.

The partial falsification of Claim 2 (bare-atom callers outside the two
named sites are not protected) does not conflict with Claims 3 or 4: Claims
3 and 4 do not assert broad drift-proofing. The narrowed Qualifier on
Claim 2 is compatible with the scoped assertions of Claims 3 and 4.

One minor internal tension: the solution notes in Open Questions that a
companion test asserting `Tau.Providers.Config.finch_name()` equals the
registered pool name "would close the last nominal-equality gap." This is an
acknowledged residual, not a contradiction. It does not affect correctness of
the four claims; it is an optional strengthening noted as out of scope for
the acceptance criterion.

---

## Falsification summary

| # | Claim (short) | Strategy | Outcome | Action |
|---|---|---|---|---|
| 1 | `Tau.Finch` default crashes with `:noproc` | Dependency check | Withstood | None |
| 2 | Shared `finch_name/0` eliminates drift at both sites | Counter-example construction | Partially falsified — scope narrowed to the two named sites | Narrow qualifier; no solution revision |
| 3 | `Application.get_env` escape hatch preserved | Type-level check | Withstood | None |
| 4 | No other files require updating | Dependency check | Withstood | None |

---

## Revision required

None. All claims withstood or had their qualifier narrowed to a scope still
consistent with the acceptance criterion. The acceptance criterion
(`problem.md`) requires only that `Finch.request/3` in `EmbeddingWorker`
resolves the registered pool in a standard `mix run` / release environment;
all four claims, under their final qualifiers, are consistent with that
criterion being met by the proposed change.

---

## Outstanding doubts

1. **Companion equality test absent.** The solution acknowledges that a
   property test asserting `Tau.Providers.Config.finch_name() == the atom
   registered by Tau.Application` is not required by the acceptance
   criterion. Without it, a future rename of the pool in `application.ex`
   that forgets to update `config.ex` would be caught only at runtime (the
   crash would reappear). This is a named residual, not a falsification of
   the solution.
2. **Namespace placement unresolved.** The solution defers the choice
   between `Tau.Providers.Config`, `Tau.Config`, and `Tau.Infrastructure` to
   project convention. Neither `Tau.Config` nor `Tau.Infrastructure` exist
   today; `lib/tau/providers/` is the natural home given all current
   `Tau.Providers.Finch` consumers live there. No falsifying case; this is
   a discoverability preference, not a correctness question.
3. **Six existing bare-atom callers.** `mcp/transport/http.ex`,
   `mcp/transport/sse.ex` (×2), `providers/shared/finch_stream.ex`,
   `providers/copilot/auth.ex` all reference `Tau.Providers.Finch` directly.
   They are correct today (the atom matches the registration). They are
   outside the scope of this solution. A future pool rename would still need
   to update them manually; the shared constant does not protect them unless
   they are migrated to use `finch_name/0`.
