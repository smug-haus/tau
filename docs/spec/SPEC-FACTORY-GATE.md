# SPEC: Factory Gate (gate orchestration · mechanical floor · polyglot Toolchain)

| | |
|---|---|
| **Status** | Draft |
| **Date** | 2026-06-10 |
| **Scope** | Component **G** of the autonomous factory: the transient gate fan-out, the three mechanical gates (`AcLinkage`, `Masking`, `Mutation`) + `SpecMembership`, the engine-owned test-execution path (HR-3), and the `Tau.Factory.Toolchain` polyglot behaviour seam (D-S2). Owns oracle separation, gating-test immutability, the non-vacuous (mutation) check, the incomplete-fix test, mechanized spec-membership + OTP-lint, and the game-resistance floor. The single highest-risk surface — gate-gaming — is mechanically resisted here. |
| **Method** | PSDH (`.claude/skills/design-reasoning`); L0 + boundary contracts. Derived from the verified architecture in `docs/arch/` (system-architecture §1 G + Toolchain, §3 enforcement matrix; `04-software-architecture/gate-and-toolchain.md`; `05-verification/synthesis.md` HR-2/HR-3/HR-6/HR-8). |
| **Issue** | TBD — file before the first implementation PR (`tau-github-workflow`); reference as `Closes #N`. |

**Changelog:** Initial draft — §0–§7 + Appendix B. Introduces D-304, D-305,
D-306, D-307, D-308, D-322, D-323, D-354. Cites (does not own) D-300
(gate-before-merge final enforcer — SPEC-FACTORY-MERGE), D-335 (append-only
verdict storage — SPEC-FACTORY-CORE's Ledger; G is the producer), D-309
(worker isolation that runs the tests — SPEC-FACTORY-FLEET), D-319
(destructive-action governance — SPEC-FACTORY-GOV). **Closes #383** (the
naive `$GATING_FILES` extraction + `mix tau.gate.masking … || true` fail-open
in `.github/workflows/ci.yml`): this SPEC's gates are path-based on the
**declared** gating-test path set, masking is detection-only routed to the
critic (never `|| true`), and AC-linkage scans only the declared
`## Acceptance criteria` section.

## 0. Why this spec exists

The factory's #1 risk is **gate-gaming**: an adversarial-or-merely-buggy
implementer that games the acceptance oracle so a non-functional change reaches
`main`. The empirical case is settled (`docs/arch/01-research/prior-art.md` §3,
*ImpossibleBench*): frontier models exploit test cases at alarming rates —
GPT-5 up to ~76% on one variant — and *stronger models cheat more*. The same
study's load-bearing mitigation findings are: (1) when test files are hidden or
read-only to the implementer, cheating drops to **near zero**; (2) an **LLM
judge alone is insufficient** — sophisticated multi-file cheats evade
LLM-monitor oracles; (3) the **mutation check** (revert production, require a
gating test to fail) closes the *vacuous-test* hole. Component G is where these
three mechanical mitigations live, with the judgement oracles (critic, reviewer)
**backing** the mechanical floor — never replacing it.

G is also the realization of the polyglot constraint **D-S2**: the engine is
language-agnostic and cannot itself run a Rust/JS/Go test suite — only a
per-language Toolchain adapter knows how. The naïve seam (adapter runs the
mutation test and reports pass/fail) is **circular**: the adversary-suspect
adapter judges its own mutation result, so a malicious or buggy adapter fakes the
PASS and defeats the entire anti-gaming posture (`synthesis.md` HR-3,
volatility-split FATAL-adjacent hole). **HR-3 — the engine owns test execution —
is the headline of this SPEC** and is load-bearing; it MUST NOT regress.

This SPEC also **closes #383.** The CI gates as shipped extract the gating-test
file set with a naïve `grep -oP` over every backtick-quoted `.exs` token in the
PR body (catching prose mentions, not the declared set) and run masking under
`mix tau.gate.masking … || true` (fail-open, so a flagged masking is silently
swallowed). This SPEC fixes both: the test/production boundary is the
**declared `## Gating-test paths` set** (frozen at scope-freeze, never commit
attribution); masking is **detection-only and surfaced to the critic**, never
`|| true`; AC-linkage scans **only** the declared `## Acceptance criteria`
section.

The component is maximally coordination-heavy (triage 5/5; §1) and therefore
requires this spec before any implementation PR modifies the gate or Toolchain
boundary, per `.claude/rules/spec-before-code.md`.

## 1. Triage

| # | Property | Score | Evidence |
|---|----------|-------|----------|
| 1 | Shared mutable state | 1 | A gate run reverts a shared working tree to the merge-base (mutation half), runs subprocesses against an isolated workspace, and appends a verdict to the durable Ledger L; the declared gating-test path set is read by every half. No half may corrupt another's view of the tree. |
| 2 | Temporal coupling | 1 | The mutation cross-check is strictly ordered: revert → run-reverted → judge → run-real → cross-check; the reverted-run failing ids must precede and bind the real-run passing ids. A verdict is appended to L only *after* all halves fold (WAL-before-effect, cited D-335). |
| 3 | Cross-process coordination | 1 | G is a bounded fan-out (`Task.async_stream` under `Task.Supervisor GateTasks`) of N halves; two halves are LLM-driven W workers (critic, reviewer); test execution is an engine-owned `Port` subprocess in a W-isolated workspace. Coordination spans the gate task, the engine `Port`, and two oracle workers. |
| 4 | Feedback loops | 1 | A masking/incomplete-fix/challenge finding appends a *superseding revoke* to a prior green verdict; a gate FAIL feeds the U refine/pivot ladder; an upheld challenge re-runs the mutation half against the corrected test. The gate's output feeds back into its own re-run. |
| 5 | State accumulation | 1 | Verdicts accumulate append-only per `(hash, run, half)`; the masking findings and challenge rulings accumulate per PR; the mutation killed-id set accumulates the cross-check binding. The full verdict lineage survives across refine cycles. |

**Triage score: 5/5. L0 + boundary contracts indicated.**

## 2. Component decomposition

Naming is precise so §4 contracts attach to specific operations. All modules are
under the `Tau.Factory.*` / `Tau.Toolchain.*` namespaces. G is a **transient
computation**, not a process — there is no `Gate` GenServer (OTP non-negotiable
#3: no GenServer wrapping stateless logic; arch `gate-and-toolchain.md` §1).

| # | Component | Role |
|---|-----------|------|
| C1 | `Tau.Factory.Gate` | **G.** The transient run: `run/1` is a **bounded fan-out** (`Task.Supervisor.async_stream_nolink` over `Tau.Factory.GateTasks`, `max_concurrency` = policy-pinned) then a fold. Holds **no state between runs**; computes a `%Verdict{}`, hands it to U to append to L. PASS iff ALL halves PASS; the floor `{mutation, critic, reviewer}` is engine-fixed (cite HR-8). |
| C2 | `Tau.Factory.Gate.AcLinkage` | Pure. Every `AC-N`/`D-NNN` token in the PR body's declared `## Acceptance criteria` section appears in a gating-test name or `@tag`; meta-ACs exempt. Properties before examples. |
| C3 | `Tau.Factory.Gate.Masking` | Pure, **detection-only**. Path-based diff scan of deleted/weakened assertions + any diff hunk whose path ∈ the declared gating-test set. Returns `{:clean \| :flagged, findings}` — **no verdict**; findings route to the critic (C7). Never `|| true`. |
| C4 | `Tau.Factory.Gate.Mutation` | Pure planning + pure judgement. `plan/2` produces the reverted-tree plan (revert `tracked ∖ gating_paths` to merge-base) + the gating-test invocation; `judge/1` is a pure predicate over the **engine-parsed** report. Performs **no I/O** (HR-3). |
| C5 | `Tau.Factory.Gate.SpecMembership` | Pure. A diff hunk touching a SPEC source-map boundary with no `SPEC-*`/`D-NNN` token in the PR body ⇒ FAIL naming that boundary (mechanizes INV-23, HR-6). |
| C6 | `Tau.Factory.Engine.TestRun` | **Engine-side, trusted.** Runs a `TestDescriptor` subprocess in a host-isolated workspace via a `Port`, captures the artifact, selects a **trusted engine-side parser by the report format tag**, parses it itself, returns an engine-produced `%TestReport{}`. The adapter never touches the verdict path. The HR-3 fix. |
| C7 | `Tau.Factory.Gate.Oracle` (critic, reviewer) | The two judgement halves: LLM-driven W workers returning structured `%OracleVerdict{}`. They **back** the mechanical floor (mandatory critic adjudication of every Masking finding; sole ruler of a challenge; the INV-9 incomplete-fix verdict rule). They **add** judgement; they cannot subtract from the floor. *(W topology cited from SPEC-FACTORY-FLEET.)* |
| C8 | `Tau.Factory.Toolchain` | **The D-S2 polyglot seam (behaviour).** Per-language adapter; every callback returns a **declarative descriptor** (recipe + machine-readable report format + resource-namespace declaration), **never a verdict and never a side-effecting run**. First adapter: `Tau.Factory.Toolchain.Elixir` (self-host). |
| C9 | `Tau.Toolchain.ReportParser` | **Engine-owned, trusted, total.** Parses a captured test artifact by **format tag** (`:junit \| :tap \| …`), not by language. The adapter cannot inject a parser. Format-keyed, so the parser set is far smaller than the adapter set. |

Boundaries (B-N attach contracts in §4):

| # | Boundary | Operation |
|---|----------|-----------|
| B1 | **U** ↔ C1 Gate | `run(request)` → `%Verdict{}`; `request = (unit, diff, frozen_paths, policy_pin)`. **Cited edge** (U owned by SPEC-FACTORY-CORE). |
| B2 | C1 Gate ↔ {C2,C3,C4,C5} mechanical halves | pure half-invocations folded into the verdict. |
| B3 | C4 Mutation ↔ C6 Engine.TestRun | `plan/2` → engine reverts + runs + parses; `judge/1` applied to the **engine-parsed** report; cross-check on failing-id ⊆ real-run passing-ids. **HR-3 boundary.** |
| B4 | C6 Engine.TestRun ↔ C8 Toolchain (adapter) | `test_descriptor/1` / `mutation_descriptor/1` / `lint/1` — adapter returns **data only**; engine executes. **HR-3 trust boundary.** |
| B5 | C6 Engine.TestRun ↔ C9 ReportParser | `parse(artifact, format_tag)` — engine selects a trusted parser by format tag; adapter never supplies one. |
| B6 | C3 Masking ↔ C7 Oracle (critic) | every Masking finding is a mandatory critic review item (detection-only → judgement). |
| B7 | C1 Gate ↔ **L** (Ledger) | `append_verdict(hash, run, half, status)` / `revoke_verdict(hash, run)` — append-only (cite D-335). **Cited edge** (L owned by SPEC-FACTORY-CORE). |
| B8 | C6 Engine.TestRun ↔ **W** workspace | the host-isolated workspace + resource namespace the engine runs the subprocess in. **Cited edge** (SPEC-FACTORY-FLEET / D-309). |
| B9 | C8 Toolchain ↔ W isolation | `declare_resource_namespace/1` — the complete mutable-path set W isolates per worker. **Cited edge** (D-309). |

## 3. L0 constraints

Format: `[Cn-Bm]` = constraint number + boundary. **★** marks non-obvious.

### Q1: What can be written by more than one actor?

- **★ [C200-B7]** A gate verdict is **never mutated in place**. G is the only
  legal producer of a verdict, and it *appends* — a later masking, incomplete-fix,
  or challenge finding appends a **superseding revoke** keyed `(hash, run, half)`,
  never an update (cite D-335 / HR-2). "Latest status for a hash" is a query over
  the append-only rows. Two writers of one verdict coordinate is forbidden by
  construction — there is exactly one producer (G) and the store is insert-only.
- **★ [C201-B3]** The **mutation half mutates a shared working tree** (revert
  `tracked ∖ gating_paths` to merge-base). This revert MUST happen in a
  host-isolated workspace (W; cite D-309), never the parent checkout — two
  concurrent gate runs reverting a shared tree corrupt each other. The declared
  gating-test paths are kept at the test-author's committed state and restored
  separately, so the revert touches no test-author work.
- **[C202-B7]** The declared gating-test **path set** is the sole test/production
  boundary; it is frozen at scope-freeze (cite SPEC-FACTORY-CORE / FR-1.3) and
  read identically by AcLinkage, Masking, and Mutation. No half re-derives the
  boundary from commit attribution.

### Q2: What ordering assumptions are implicit?

- **★ [C203-B3]** **The mutation cross-check is strictly ordered**: (1)
  `plan/2` [pure]; (2) engine reverts tree-minus-gating-paths to merge-base
  [engine/git]; (3) adapter yields `mutation_descriptor` [data]; (4) engine runs
  + parses the reverted report; (5) `judge/1` yields `{:pass, killed_ids}`
  [pure]; (6) engine runs + parses the **real** report; (7) engine asserts
  `killed_ids ⊆ passing_ids(real_report)`; (8) half PASS iff 5 ∧ 7. The reverted
  run MUST precede and bind the real run — a faked report cannot satisfy *both* a
  structurally-valid failing artifact on the reverted tree **and** a matching
  passing id on the real tree, because the **engine** (not the adapter) produced
  and parsed both.
- **★ [C204-B7]** A verdict is appended to L **only after** all halves fold; the
  external effect of a green verdict (the merge lease M reads) is visible only
  once the verdict is durable (cite D-335 WAL-before-ack). No half's partial
  result is externally visible.
- **[C205-B1]** The gate composition (manifest) is **pinned at admission** into
  the unit's policy-pin (cite HR-8); a mid-flight manifest change cannot de-gate
  an in-flight unit. `compose/1` reads the pin, not live policy.

### Q3: What happens if a component fails silently?

- **★ [C206-B4]** **HR-3, the load-bearing fix.** The Toolchain adapter is on the
  **untrusted** side. If it returned a verdict (or chose the parser, or saw the
  green-run ids), a malicious or buggy adapter could fake the mutation PASS and
  defeat INV-7 / NFR-GAME-RESISTANCE entirely. The adapter therefore returns
  **only** a declarative descriptor `{argv, env, report: <format>, artifact:
  <rel_path>}` — no verdict, not even "tests ran". The **engine** runs the
  subprocess, **parses the artifact itself** (a trusted parser selected by format
  tag, §C9), and applies the pure `judge/1`. A malformed descriptor, absent
  artifact, or crashing recipe yields a **half FAIL (fail-closed)**, never a
  bypass.
- **★ [C207-B6]** Masking is **detection-only and never `|| true`** (closes
  #383). A flagged masking is a **mandatory critic review item**, not a silent
  pass and not a self-authored bypass tag. A masking gate that swallows its own
  finding (`|| true`) is a gate bypass and is forbidden. The verdict on a masking
  finding is the **critic's**, on the surfaced findings.
- **★ [C208-B2]** An LLM judge alone is insufficient (`prior-art.md` §3). The two
  oracle halves **back** the mechanical floor; a critic PASS does **not** excuse a
  mechanical-half FAIL, and the floor `{mutation, critic, reviewer}` is
  engine-fixed and non-shrinkable by policy (cite HR-8). An operator cannot policy
  away the critic.
- **[C209-B2]** A crashed half (e.g. a critic worker exit) folds to **FAIL**, not
  a coordinator crash: `async_stream_nolink` surfaces `{:exit, reason}` for that
  half, which folds FAIL (crash isolation; arch INV-17).

### Q4: What information crosses a boundary, and what is lost?

- **★ [C210-B5]** The adapter crosses **only a recipe + a format tag**; the engine
  selects the parser. The parser set is keyed on report **format** (JUnit, TAP),
  not **language** — many languages emit JUnit-XML, so the trusted parser set is
  far smaller than the adapter set. The adapter cannot inject a parser, assert a
  pass, or see the cross-check ids it would need to forge (closes the FC-5
  malicious-adapter hole).
- **★ [C211-B7]** A verdict crossing G→L carries its full provenance: `(hash,
  run, half, status, findings, killed_ids)`. No verdict is reduced to a bare
  boolean — the merge-CAS value-staleness contract and NFR-AUDIT need the full
  lineage (the failing→passing id binding is the audit trail).
- **[C212-B2]** AcLinkage scans **only** the declared `## Acceptance criteria`
  section (closes #383). Tokens appearing only in Background prose are context,
  never claims, and are NOT checked. The boundary of "what is claimed" is the
  section, not the whole body.

### Q5: Where are the feedback loops, and are they bounded?

- **★ [C213-B7]** The revoke loop (a late finding revokes a prior green verdict)
  is bounded by append-only construction: each finding appends exactly one
  superseding row; "latest status" is a query, never an unbounded rewrite (cite
  D-335). A revoke does not re-run the gate; the *next* gate run (driven by U's
  bounded refine ladder, cite SPEC-FACTORY-CORE / D-318) does.
- **[C214-B6]** The challenge loop (an implementer challenges a gating test that
  contradicts a SPEC §4 clause) is ruled by an **independent critic**, not the
  coordinator's judgement; an upheld challenge re-runs the mutation half against
  the corrected test. `> 2` upheld challenges on one PR escalates `E-CHALLENGE`
  (cited from SPEC-FACTORY-CORE) — the loop is bounded.

### Q6: What are the pre/post-conditions at each boundary?

- **[C215-B1]** `run/1` pre: `frozen_paths` non-empty (or the unit claims no
  `AC-N`/`D-NNN`, in which case AcLinkage/Mutation are skipped per the
  out-of-scope exemption); `policy_pin` present. Post: `%Verdict{}` with `status =
  PASS` iff every half (incl. the engine-fixed floor) returned PASS on exactly
  `diff`.
- **[C216-B3]** `Gate.Mutation.judge/1` pre: `report` is engine-parsed (not
  adapter-supplied). Post: `{:pass, killed}` ⟺ `report` has ≥1 `:failed` case;
  `{:na, :project_created}` when every gating path's nearest-ancestor build
  manifest is absent at merge-base (PR-created sub-project); else
  `{:fail, :no_test_failed}` (vacuous suite).

### Q7: What is the message-ordering protocol?

- **★ [C217]** The gate **fan-out is `Task.async_stream`** (bounded, the
  `max_concurrency` is the back-pressure), **not** Broadway/GenStage — the gate's
  inputs are fixed at call time (a bounded fan-out over a single pass, then a
  fold; arch research OTP §6). The two oracle halves are W workers consumed as
  stream elements. Crash isolation is `async_stream_nolink`. **No `:global`, no
  `Process.whereis |> send`** (OTP non-negotiable #4).
- **[C218]** Adapter selection is by **atom pattern-match** (`Toolchain.for(:elixir
  \| :node \| …)`), never string-keyed dispatch (OTP non-negotiable #2:
  extensibility seams are behaviours).

### Q8: What is the change-impact (what else must move if this changes)?

- **[C219]** Adding a gate half changes `compose/1` and the verdict fold; a floor
  member (`{mutation, critic, reviewer}`) may be **added to** but never removed
  (HR-8) — removing one falsifies INV-1/INV-7 and requires a SPEC-FACTORY-GOV
  policy-clamp change in the same PR. Adding a new report **format** adds a
  trusted engine-side parser (§C9) — a format-keyed addition, not per-language.
  Adding a Toolchain adapter is a new behaviour impl with **no** new trust surface
  (its output is advisory data).

## 4. Boundary contracts

### B1: Unit (U) ↔ Gate (C1) — *cited edge, SPEC-FACTORY-CORE*

- `run/1 :: (%Request{unit, diff, frozen_paths, policy_pin}) -> %Verdict{}`.
- Pre: `policy_pin` present (manifest pinned at admission, HR-8); `frozen_paths`
  is the declared gating-test path set (empty ⇒ AcLinkage/Mutation skipped per
  the `AC-N`/`D-NNN`-free exemption).
- Post: `Verdict.status == PASS` ⟺ **every** half PASS on exactly `diff`, AND the
  engine-fixed floor `{mutation, critic, reviewer}` is present in `compose(pin)`.
- Invariant (**D-354**): the gate floor is **non-shrinkable by policy**;
  `compose/1` re-asserts floor membership rather than trusting the pin. A policy
  that omits a floor member is rejected, not honoured.

### B2: Gate (C1) ↔ mechanical halves (C2–C5)

- `AcLinkage.check/2 :: (pr_body, gating_tests) -> {:pass, []} | {:fail, [token]}`.
- `Masking.scan/2 :: (diff, gating_paths) -> {:clean | :flagged, [Finding]}`.
- `Mutation.plan/2 :: (merge_base, gating_paths) -> %Plan{}`;
  `Mutation.judge/1 :: (report) -> {:pass, [id]} | {:fail, :no_test_failed} | {:na, reason}`.
- `SpecMembership.check/3 :: (diff, pr_body, source_maps) -> {:pass, []} | {:fail, [boundary]}`.
- Invariant (**D-306 / D-322**, properties §6): all four are **pure**
  (referentially transparent, property-testable in isolation); `plan/2` and
  `judge/1` perform **no I/O**.

### B3: Mutation (C4) ↔ Engine.TestRun (C6) — *HR-3 boundary*

- The mutation half executes the §C203 ordered sequence. `judge/1` is applied to
  the **engine-parsed** `%TestReport{}`, never an adapter-supplied result.
- Cross-check (binding): the engine asserts `killed_ids ⊆ passing_ids(real_report)`
  — the specific test ids that failed on the reverted tree MUST appear **passing**
  in the green real run for the same `hash`, both runs engine-produced.
- Invariant (**D-306**): `judge(report) = {:pass, _}` ⟺ `report` has ≥1 `:failed`
  case AND the cross-check holds; a suite passing wholesale against the
  production-absent reverted tree is `:fail` (the vacuous-test hole closed).

### B4: Engine.TestRun (C6) ↔ Toolchain adapter (C8) — *HR-3 trust boundary*

- `@callback test_descriptor(ctx) :: %TestDescriptor{argv, env, report, artifact}`;
  `mutation_descriptor(ctx)`; `lint(ctx) :: %LintDescriptor{}`. All return
  **data only** — no verdict, no side-effecting run.
- The engine runs the subprocess (`Port`), captures the artifact, parses it (B5),
  judges it. The adapter never reaches the verdict path, the parser choice, or
  the green-run ids.
- Invariant (host-enforced, **all adapters**): adapter output is **advisory data,
  never control**. A malformed descriptor / absent artifact / crashing recipe ⇒
  **half FAIL** (fail-closed). No adapter callback can relax the gate floor (B1),
  the merge serialization (cited M), or the isolation boundary (cited W).

### B5: Engine.TestRun (C6) ↔ ReportParser (C9)

- `ReportParser.parse/2 :: (artifact_bytes, format_tag) -> %TestReport{}` —
  total, engine-owned. `format_tag ∈ {:junit, :tap, …}` is the adapter's `report`
  field; the engine selects the parser, the adapter does not supply one.
- Invariant: the parser set is keyed on **format**, not language; adding a
  language that emits an existing format adds **no** parser (the §3 cost bound).

### B6: Masking (C3) ↔ Oracle critic (C7)

- Every `Finding` from `Masking.scan/2` is a **mandatory critic review item**.
- Invariant (**D-305**): detection-only — `scan/2` never returns PASS/FAIL; the
  verdict on a masking finding is the critic's. There is **no self-authored
  bypass tag** and **no `|| true`** (closes #383).

### B7: Gate (C1) ↔ Ledger L — *cited edge, SPEC-FACTORY-CORE / D-335*

- `append_verdict(hash, run, half, status, provenance)` / `revoke_verdict(hash,
  run)` — **inserts only**; a revoke is a superseding row with `supersedes_id`.
- Invariant: G is the **sole legal producer** of a verdict; M (SPEC-FACTORY-MERGE,
  D-300) reads the **latest** status inside its CAS. Value-staleness is closed by
  append-only immutability (cite D-335 / HR-2), not by G.

### B8: Engine.TestRun (C6) ↔ Worker workspace W — *cited, SPEC-FACTORY-FLEET / D-309*

- The engine runs the subprocess in a **host-isolated workspace** (private
  checkout + the complete resource namespace W allocated from
  `declare_resource_namespace/1`). The revert (C201) and both runs happen there,
  never in the parent checkout. W owns the isolation invariant (D-309).

### B9: Toolchain (C8) ↔ W isolation — *cited, SPEC-FACTORY-FLEET / D-309*

- `@callback declare_resource_namespace(ctx) :: [%ResourceNS{}]` — the **complete**
  set of mutable paths the toolchain touches outside the git checkout
  (HOME-namespace caches, XDG dirs, per-language download caches). W allocates a
  per-worker namespace over exactly these; declarative data, the adapter cannot
  opt out.

## 5. State enumeration

G holds **no state between runs** (it is transient; arch `gate-and-toolchain.md`
§1). The "states" of a gate run are the per-half verdict-assembly stages and the
fold; the durable state lives in L (verdicts, append-only).

### Gate run (C1 `run/1`) — fan-out + fold (not a process)

| Stage | Meaning | Entry | Exit |
|-------|---------|-------|------|
| `composing` | `compose(policy_pin)` selects halves; floor re-asserted | `run/1` called | manifest = floor ⊎ policy-added halves |
| `fanning_out` | `async_stream_nolink` over halves, `max_concurrency` bound | manifest fixed | every half returns `{id, result}` (a crashed half ⇒ `{:exit, _}` ⇒ FAIL) |
| `folding` | `Verdict.fold/1`: PASS iff every half PASS | all halves returned | `%Verdict{status, halves, provenance}` |
| `appended` | verdict handed to U → appended to L (cite D-335) | fold complete | L commit acked (WAL-before-effect) |

### Mutation half (C4+C6) — the HR-3 ordered sequence

```
plan ─(pure)→ revert(tree ∖ gating_paths → merge_base) ─(engine/git, isolated ws)→
  run_reverted ─(engine Port + parse)→ judge ─(pure)→ {:pass, killed_ids}
    run_real ─(engine Port + parse)→ cross_check(killed_ids ⊆ passing_ids(real))
      half PASS iff judge=:pass ∧ cross_check
  judge=:fail (no test failed → vacuous)              → half FAIL
  judge={:na, :project_created} (sub-project PR-created) → half PASS (no production to revert)
  descriptor malformed ∨ artifact absent ∨ recipe crash → half FAIL (fail-closed, HR-3)
```

The reverted run MUST precede and bind the real run (C203). Both runs are
**engine-produced**; the adapter supplies only the recipe + format tag.

### Verdict (in L) — append-only per `(hash, run, half)`

| Status | Meaning | Transition |
|--------|---------|------------|
| `PASS` | the half passed on exactly `diff` | inserted once per `(hash, run, half)` |
| `FAIL` | the half failed (incl. vacuous, fail-closed, crashed half) | inserted once per `(hash, run, half)` |
| `revoked` | a later finding superseded a prior PASS | a **new row** with `supersedes_id`, never an update (D-335) |

`merged` requires a fresh `PASS` for every required floor half for the exact
`hash` (cite D-300, M's CAS). Illegal: an in-place mutation of a verdict — no
update changeset exists.

## 6. D-NNN invariants

> Owned by this SPEC. Each names its detection method. Cited D-NNN (core/merge/
> fleet/gov) are enforced by their owner SPEC and only *consumed* here.

**D-304 — Oracle separation (INV-5):**
The party that authors the gating tests is distinct from the party that
implements: `author(test_g) ≠ author(impl)`. The test-author runs and **freezes a
declared gating-test path set** before any implementer is spawned; the authoring
agent identity is recorded (HR-7), and a gating test whose authoring identity is
the implementer is rejected. The frozen declared path set — **not commit
attribution** — is the test/production boundary every mechanical half keys on.
Enforced by `oracle_separation_test.exs` (a same-identity gating test ⇒ rejected)
+ the recorded-identity check; the path-set freeze is the SPEC-FACTORY-CORE
scope-freeze (FR-1.3) this SPEC consumes.

**D-305 — Gating-test immutability, detection-only (INV-6):**
`Gate.Masking.scan/2` flags (a) any diff hunk deleting/weakening an assertion
(`-  assert`, `-  refute`, or an assertion replaced by a weaker predicate) and
(b) **any** diff hunk whose path ∈ the declared gating-test set, *independent of
commit attribution* (path-based, so it survives a refine-cycle rebase). It is
**detection-only**: `scan/2` returns `{:clean | :flagged, findings}` and **never**
a verdict; every flagged hit is surfaced to the **critic** as a mandatory review
item — there is no self-authored bypass tag and **no `|| true`** (closes #383).
Enforced by the property suite `masking_property_test.exs` (P-MK1 assertion-
deletion detection; P-MK2 path-violation detection independent of author; P-MK3
no-verdict/detection-only; P-MK4 rebase-invariance; tagged `:property`).

**D-306 — Non-vacuous acceptance, engine-executed mutation (INV-7):**
`Gate.Mutation.plan/2` reverts exactly `tracked_paths ∖ gating_paths` to the
merge-base, keeping `gating_paths` at the test-author's committed state; the
**engine** (not the adapter, HR-3) runs the gating tests in a host-isolated
workspace, parses the structured artifact itself, and applies the pure `judge/1`:
`{:pass, killed_ids}` ⟺ ≥1 `:failed` case. The engine **cross-checks** that
`killed_ids` appear **passing** in the green real run for the same `hash`. A
suite that passes wholesale against the production-absent reverted tree is
`:fail` — the vacuous-test hole closed. Enforced by `mutation_property_test.exs`
(P-MU1 non-vacuity⇒pass; P-MU2 boundary = declared paths; P-MU3 project-creation
N/A; P-MU4 purity of `plan`/`judge`; tagged `:property`) **and**
`engine_test_run_test.exs` (the engine — not the adapter — runs, parses, and
cross-checks; a stubbed adapter cannot inject a verdict). Both halves required:
purity of `judge` alone does not establish that the *engine* executes.

**D-307 — User-path oracle (INV-8) — ◐ PARTIAL (honest residual):**
What mutation (D-306) + oracle-separation (D-304) + path-based masking (D-305)
**do NOT** mechanically close:
- **Under-asserting tests** — a gating test that runs the real path but asserts
  too little (checks `exit 0` but not the output) *fails on the reverted tree*
  (so it passes D-306) yet does not pin the behaviour. Mutation cannot catch this:
  the test *does* depend on production, just weakly.
- **Wrong-path tests** — a test exercising a hand-built struct rather than the
  real user entry point (`Tau.CLI.main([...])` with realistic argv) can pass
  D-306 while never proving the user-facing behaviour.
HR-3 lets the engine assert the declared user-entry symbol **appears** in the
gating test (a mechanizable *narrowing*), and the cross-check (D-306) binds the
failing id to the real run — but "appears in the test" is not "is the exercised
path". Deciding whether the test **drives** the real entry point remains
**critic judgement** (C7). This is the **one honestly-partial cell** (`◐ INV-8`
in the enforcement matrix; NFR-GAME-RESISTANCE explicitly refuses a number here).
**Stated, not claimed closed.** Detection of the *narrowed* part:
`entry_symbol_presence_test.exs` (engine asserts the declared entry symbol occurs
in the gating test) — the residual is bounded only by the critic, by design.

**D-308 — Incomplete-fix mechanical test (INV-9):**
A critic/reviewer finding that **falsifies a named `AC-N`/`D-NNN`** the PR claims
(in the declared `## Acceptance criteria` section or its linked SPEC) forces
**reopen-and-refine** — it MAY NOT be deflected to a follow-up regardless of
severity (`info`/`suggestion` does not lower the bar). The test is mechanical: for
each named AC, does the finding describe a state that falsifies it? If yes for any
AC, the merge is incomplete. Enforced as a **verdict rule** in `Gate.Oracle`
adjudication + `incomplete_fix_test.exs` (a finding falsifying a named AC ⇒
verdict FAIL/reopen, never a follow-up; a finding outside every named AC ⇒
admissible follow-up).

**D-322 — Spec-before-code mechanized (INV-23):**
`Gate.SpecMembership.check/3` loads the SPEC source-maps (Appendix B of every
`docs/spec/SPEC-*.md`, the catalog in `spec-before-code.md`) and FAILs a diff
that touches any source-map boundary path **without** a `SPEC-*`/`D-NNN` token in
the PR body, naming that boundary (mechanizes the mechanizable half of INV-23;
HR-6). A diff touching only non-SPEC'd paths ⇒ PASS regardless of body. Enforced
by `spec_membership_property_test.exs` (P-SP1 SPEC'd-boundary-without-reference ⇒
fail naming it; P-SP2 non-SPEC'd-only ⇒ pass; tagged `:property`).

**D-323 — OTP non-negotiables mechanized via the Toolchain (INV-24):**
The mechanizable part of INV-24 (`mix compile --warnings-as-errors`, `mix format
--check-formatted`, `mix credo --strict`, `mix dialyzer` — and per-language
analogues) runs as a gate half through `Toolchain.lint/1`, **executed by the
engine** exactly as the mutation descriptor is (HR-3): the adapter supplies the
`%LintDescriptor{}` recipe; the engine runs it and judges `exit_status`. A
non-zero exit ⇒ half FAIL. The **residual** the critic still owns is the
genuinely-judgement part of INV-24 (e.g. "is this `GenServer` wrapping stateless
logic?", "is this `:global` a violation?") — removed from the critic's plate is
only the mechanizable part (HR-6). Enforced by CI wiring (`lint` job runs the
LintDescriptor steps; warnings-as-errors + credo --strict + dialyzer) + a unit
asserting a non-zero lint exit folds the half FAIL.

**D-354 — Game-resistance: vacuous fraction = 0 (NFR-GAME-RESISTANCE):**
Under an adversarial-implementer assumption, the fraction of **vacuous** tests
(passing against the reverted production tree) that reach `main` is **0**,
mechanically guaranteed by D-306 (mutation) + HR-3 (engine execution). The gate
floor `{mutation, critic, reviewer}` is **engine-fixed and non-shrinkable by
policy** (cite HR-8): `compose/1` re-asserts floor membership and rejects a policy
that omits a floor member. A **malicious or buggy Toolchain adapter cannot defeat
the mutation gate** — it returns only a recipe + format tag; the engine runs,
parses, and cross-checks (HR-3). Under-asserting/wrong-path tests are **not**
bounded by a number (the D-307 residual). Enforced by
`game_resistance_test.exs` (a vacuous gating test cannot reach a PASS verdict; a
stubbed-malicious adapter returning a fabricated pass-report does not fold the
mutation half PASS because the engine — not the adapter — produces and parses
both runs) + `floor_nonshrinkable_test.exs` (a policy pin omitting `:critic` is
rejected by `compose/1`).

## 7. Acceptance criteria

Each is expressed against an observable signal. A vacuous gating test cannot reach
`main` (D-306); a malicious adapter faking its own test result cannot defeat the
mutation gate (HR-3, D-354); an implementer edit to a declared gating-test path is
flagged to the critic (D-305); a diff touching a SPEC'd boundary without a D-NNN
fails (D-322). PR groupings are indicative. **This SPEC closes #383.**

- **AC-1 (PR-GATE-1):** `mix compile --warnings-as-errors` passes with
  `Tau.Factory.Gate` + `Tau.Factory.Gate.{AcLinkage, Masking, Mutation,
  SpecMembership}` present (lifted from `lib/mix/gate/`). Signal: `mix test`
  compiles the gate modules.
- **AC-2 (PR-GATE-1, D-305):** `mix test --only property` passes including
  `masking_property_test.exs` (P-MK1..4) — a diff hunk whose path ∈ the declared
  gating-test set is flagged independent of commit author, and `scan/2` returns no
  verdict. Signal: the property suite asserts detection-only + rebase-invariance.
  *(Closes #383: path-based, not the naïve `$GATING_FILES` grep.)*
- **AC-3 (PR-GATE-1, D-304):** `oracle_separation_test.exs` passes — a gating test
  whose recorded authoring identity is the implementer is rejected; the declared
  frozen path set is the boundary. Signal: same-identity ⇒ rejected.
- **AC-4 (PR-GATE-2, D-306/D-354):** `mix test --only property` passes including
  `mutation_property_test.exs` (P-MU1..4); a **vacuous** gating test (passes
  against the reverted production tree) folds the mutation half FAIL and cannot
  reach a PASS verdict. Signal: `judge/1` returns `{:fail, :no_test_failed}` on a
  wholesale-passing reverted run.
- **AC-5 (PR-GATE-2, D-306/HR-3):** `engine_test_run_test.exs` passes — the
  **engine** runs the subprocess, selects the parser by format tag, parses the
  artifact, and applies `judge/1`; a stubbed Toolchain adapter that returns a
  fabricated "tests passed" descriptor **cannot** fold the mutation half PASS,
  because the verdict path is engine-owned. Signal: the malicious-adapter stub
  yields a half FAIL.
- **AC-6 (PR-GATE-2, D-354):** `game_resistance_test.exs` + `floor_nonshrinkable_test.exs`
  pass — a policy pin omitting `:critic` (or `:mutation`/`:reviewer`) is rejected
  by `compose/1`; the vacuous fraction reaching a PASS verdict is 0. Signal: the
  floor is re-asserted, not trusted from policy.
- **AC-7 (PR-GATE-3, D-322):** `mix test --only property` passes including
  `spec_membership_property_test.exs` (P-SP1/P-SP2) — a diff touching a SPEC
  source-map boundary with no `SPEC-*`/`D-NNN` token in the PR body fails naming
  that boundary. Signal: the property asserts fail-with-named-boundary.
- **AC-8 (PR-GATE-3, D-308):** `incomplete_fix_test.exs` passes — a critic finding
  falsifying a named `AC-N` forces reopen (verdict FAIL), not a follow-up,
  regardless of severity; a finding outside every named AC is an admissible
  follow-up. Signal: AC-falsification ⇒ reopen.
- **AC-9 (PR-GATE-3, D-307 ◐):** `entry_symbol_presence_test.exs` passes — the
  engine asserts the declared user-entry symbol *appears* in the gating test (the
  mechanizable *narrowing* of INV-8). The SPEC and this AC state honestly that
  **whether the test drives the real entry point remains critic judgement** — the
  under-asserting/wrong-path residual is NOT claimed closed. Signal: the test
  checks symbol presence only.
- **AC-10 (PR-GATE-4, D-323):** the `Tau.Factory.Toolchain.Elixir` adapter's
  `lint/1` descriptor runs (engine-executed) and a non-zero lint exit folds the
  half FAIL; `toolchain_elixir_test.exs` passes — every callback returns a
  declarative struct, none returns a verdict. Signal: a stubbed crashing recipe ⇒
  half FAIL (fail-closed).
- **AC-11 (meta):** the three mechanical gates run in CI as blocking jobs, with
  the gating-test boundary keyed on the declared `## Gating-test paths` section
  (not the naïve `$GATING_FILES` grep) and masking surfaced (not `|| true`).
  *(meta — verified by CI wiring in `.github/workflows/ci.yml`; this is the
  CI-level half of closing #383; exempt from the unit-test-linkage check.)*
- **AC-12 (PR-GATE-5, end-to-end / substance):** the gate drives one real PR on
  the self-hosting Elixir toolchain: a vacuous-test PR is **blocked** (mutation
  FAIL) and a genuine PR **passes** the full floor, with the verdict appended
  append-only to L. Signal: the exact `Tau.Factory.Gate.run/1` invocation + the
  observable FAIL on the vacuous diff and PASS on the real diff (the anti-gaming
  proof). *This AC depends on SPEC-FACTORY-{CORE,FLEET} landing; it is the
  integration gate, not a GATE-only unit.*

## Appendix B — Source map

Files that bring a PR into scope of this SPEC (`D-NNN`/`C-N` → file:symbol).
**Lift source:** the existing `lib/mix/gate/{ac_linkage,masking,mutation,common}.ex`
+ `lib/mix/tasks/tau.gate.*` (the `mix tau.gate.*` CLI wrappers) are relocated
into `lib/tau/factory/gate/` as pure modules; the `mix` tasks become thin CLI
shims over them.

- `lib/tau/factory/gate.ex` (C1; transient fan-out + fold; floor `compose/1`; D-354) — PR-GATE-1/2
- `lib/tau/factory/gate/ac_linkage.ex` (C2; D-322-adjacent acceptance-section scan) — PR-GATE-1
- `lib/tau/factory/gate/masking.ex` (C3; D-305) — PR-GATE-1
- `lib/tau/factory/gate/mutation.ex` (C4; D-306, D-354) — PR-GATE-2
- `lib/tau/factory/gate/spec_membership.ex` (C5; D-322) — PR-GATE-3
- `lib/tau/factory/engine/test_run.ex` (C6; HR-3 engine execution; D-306, D-323) — PR-GATE-2/4
- `lib/tau/factory/gate/oracle.ex` (C7; D-305 critic adjudication, D-308 incomplete-fix rule) — PR-GATE-3
- `lib/tau/factory/toolchain.ex` (C8 behaviour; the D-S2 seam; callbacks `install_deps`, `build`, `package`, `test_descriptor`, `mutation_descriptor`, `lint`, `declare_resource_namespace`) — PR-GATE-4
- `lib/tau/factory/toolchains/elixir.ex` (first adapter, self-host; D-323) — PR-GATE-4
- `lib/tau/toolchain/report_parser.ex` (C9; trusted, format-keyed, total) — PR-GATE-2
- `lib/tau/toolchain/{test_descriptor,lint_descriptor,test_report,resource_ns,run_error}.ex` (the declarative structs) — PR-GATE-2/4
- `.github/workflows/ci.yml` (the `lint` + `mutation-check` jobs; closes #383 — declared `## Gating-test paths` section, masking surfaced not `|| true`) — PR-GATE-1/CI (AC-11 meta)
- `test/tau/factory/masking_property_test.exs` (D-305) — PR-GATE-1
- `test/tau/factory/oracle_separation_test.exs` (D-304) — PR-GATE-1
- `test/tau/factory/mutation_property_test.exs` (D-306, D-354) — PR-GATE-2
- `test/tau/factory/engine_test_run_test.exs` (D-306, HR-3) — PR-GATE-2
- `test/tau/factory/game_resistance_test.exs` + `floor_nonshrinkable_test.exs` (D-354) — PR-GATE-2
- `test/tau/factory/spec_membership_property_test.exs` (D-322) — PR-GATE-3
- `test/tau/factory/incomplete_fix_test.exs` (D-308) — PR-GATE-3
- `test/tau/factory/entry_symbol_presence_test.exs` (D-307 ◐) — PR-GATE-3
- `test/tau/factory/toolchain_elixir_test.exs` (D-323; adapter returns data, never a verdict) — PR-GATE-4

**Cross-SPEC boundaries (cited, not owned here):** B1/B7 → `SPEC-FACTORY-CORE`
(U FSM; L append-only verdict storage, D-335; gate-floor pin HR-8; the
scope-freeze of the declared gating-test path set, FR-1.3); B7 (merge consumer) →
`SPEC-FACTORY-MERGE` (D-300, the gate-before-merge final enforcer reads G's
latest verdict in its CAS); B8/B9 → `SPEC-FACTORY-FLEET` (D-309, the host-isolated
workspace + resource namespace the engine runs tests in); `E-DESTRUCTIVE`/floor
policy-clamp → `SPEC-FACTORY-GOV` (D-319).

**Catalog registration required before first implementation PR:** add
`SPEC-FACTORY-GATE` to `.claude/rules/spec-before-code.md` (catalog) and the
`D-NNN` block table in `docs/MISSION.md` (D-304, D-305, D-306, D-307, D-308,
D-322, D-323, D-354 → this SPEC).
