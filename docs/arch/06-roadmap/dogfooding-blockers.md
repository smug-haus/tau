# Roadmap — blockers between the orchestration smoke and real dogfooding

| | |
|---|---|
| **Status** | Planning (no code) |
| **Date** | 2026-06-13 |
| **Method** | `solution-shaping` (calibrated abstention, V1 impossibility) + `design-reasoning` (PSDH triage) |
| **Owns** | A dependency-ordered removal plan. Authors no D-NNN; flags where a solution-shaping pass + new D-NNN is required *before* code. |

This document inventories every blocker between today's state
(`mix tau.factory.dogfood` — an orchestration smoke test) and genuine
**dogfooding**, surfaces the load-bearing decisions that gate the plan, and
lays out a phased removal roadmap. It does **not** change production code.

---

## 1. The goal / the bar

`mix tau.factory.dogfood` (AC-12, merged in #480/#481) is an **orchestration
smoke test**, not dogfooding. It operates on a throwaway local-bare-repo
sandbox, seeds a HARDCODED fake ticket (*add `Sandbox.answer/0` returning 42*),
and its "coding agent" is a **canned shell script** (`Tau.Factory.Dogfood.Agent`)
that emits one fixed diff. Every machinery edge is real (worker worktree, the
engine-executed mutation gate, the `--force-with-lease` CAS push, the health
check) — but the **work is fake**.

Real **dogfooding** is the factory autonomously:

1. **targeting tau's own repository** (not a sandbox);
2. **picking up a real, open tau issue** (not a seeded fixture);
3. **using a real coding agent** — `Tau.CodingAgents.ClaudeCode` via the
   `Tau.CodingAgent` substrate — to actually solve it (not a script emitting a
   fixed diff); and
4. **producing a real PR that passes tau's OWN merge gate** and lands in tau.

The arch already names this target: **AC-10 "self-hosting smoke"**
(`spec-factory.md`) — *the factory drives one real PR on its own from open issue
to merged, gate-green, with `main` health-checked.* AC-12 was the throwaway-
sandbox precursor; AC-10 is the bar this plan drives toward.

The gap is not one feature. It is (a) a small number of **load-bearing product
decisions** that nobody may pick by taste (§2), and (b) **fourteen blockers**
(§3) — several of which are genuine **ARCH GAPS** (§5) that need a solution-
shaping architecture pass and a new D-NNN before any code is written.

---

## 2. The load-bearing decisions (human/product judgement — do NOT pick by taste)

These gate the rest of the plan. Each is presented as a *discriminating
question* with options and the **cost asymmetry** of guessing wrong. They are
surfaced, not decided.

### D-DEC-1 — Merge model: PR-mode vs autonomous-merge (the safety crux)

**Discriminating question:** *On the real tau remote, does the factory* **open a
PR and stop** *(letting tau's existing critic + reviewer + CI + human gate it),
or does it* **autonomously force-merge `main`** *(the current `MergeAuthority`
`--force-with-lease` CAS, §3-G3)?*

The factory's whole merge design (`merge-and-integration.md`) is built around
M being the **sole writer of `origin/main`** via `git push --force-with-lease`.
On a sandbox this is blast-radius-confined; the dogfood **hard-refuses any
non-local origin** (D-359) precisely so it *cannot* push to real GitHub. Real
dogfooding must operate on the real remote — which collides head-on with that
guard.

**Apply verifier pattern V1 (does it assume an impossibility?) to
autonomous-merge on the real remote:** it assumes the factory's gate is a
*faithful, complete* replacement for tau's actual merge gate (critic + reviewer
LLM judgement + the full CI matrix + the human merge button). It is not (see
D-DEC-2 and blocker G2). Autonomous force-push of `main` therefore **bypasses
the review tau actually requires** and is, per tau's own `factory-loop.md` and
`governance.md` §4, a **destructive/irreversible action the gate cannot
competently assess** → `E-DESTRUCTIVE`. The arch *already* classifies a non-M
`origin/main` write as `E-DESTRUCTIVE` and forbids autonomous execution
(`governance.md` §4; `merge-and-integration.md` §3).

| Option | What it is | Cost of being wrong |
|---|---|---|
| **A — PR-mode** | The factory's terminal action is `gh pr create` (+ push the branch). It STOPS there. Tau's normal critic + reviewer + CI + human merge decide. | LOW. Worst case: a low-quality PR a human declines — recoverable, reviewable, revertible. The human gate is preserved. |
| **B — Autonomous-merge** | M force-pushes `main` on real tau after the factory's own gate goes green. | **CATASTROPHIC & irreversible.** A force-push past review can land a subtly-wrong change on `main`, rewrite history, or break every concurrent contributor's branch. The factory's gate is *not* tau's gate; a false-green merges unreviewed code into the project that builds the factory. |

**The asymmetry is maximal and one-directional.** Guessing A-when-B-was-wanted
costs a manual merge click. Guessing B-when-A-was-wanted costs an unreviewed,
possibly-irreversible mutation of the repository's trunk. **Recommendation
(not a decision): begin with PR-mode (A).** It is the cheap-to-reverse shape
(`solution-shaping` step 7: when the choice must be made without the
discriminating answer, choose the cheap-to-reverse shape and say so). Autonomous-
merge, if ever wanted, is a *later, separately-gated* graduation — never the
first dogfooding step.

This decision **cascades**: PR-mode changes the terminal seam of the Unit FSM
(`awaiting_merge` → a new `awaiting_pr` / terminal `:pr_opened`), changes what
"done" means, and **dissolves several blockers** (G3 force-push safety, parts of
G2 gate-model) because tau's real gate, not the factory's, becomes authoritative.

### D-DEC-2 — Gate model: replicate tau's critic+reviewer judgement, or defer to it?

**Discriminating question:** *Does the factory's gate need to* **include the
critic + reviewer LLM judgement** *itself (else it merges under-reviewed), or
does it* **defer** *that judgement to tau's existing gate by opening a PR?*

This is **not independent of D-DEC-1** — it is its other face. The factory's
`Gate.run` floor is `[:mutation, :critic, :reviewer]` (`gate.ex`), but the
`critic`/`reviewer` **`Real` oracle is an unimplemented fail-closed stub**
(`gate/oracle.ex` — `Real.judge/2` returns `:fail`, "LLM worker path lands in
P5c-3"). The dogfood only passes because `GateFun` pins `oracle: %{critic: :pass,
reviewer: :pass}` — i.e. it **stubs the judgement to always-pass**. So today the
factory has *no real LLM judgement at all*.

| Option | What it is | Cost of being wrong |
|---|---|---|
| **A — Defer (pairs with PR-mode)** | The factory runs only the mechanical floor (mutation + lint + ac-linkage) + CI-equivalent locally, then opens a PR. Tau's real critic + reviewer + human do the judgement. | LOW. The LLM judgement happens — just on tau's side, where it already lives. No need to build the `Real` oracle before dogfooding. |
| **B — Replicate (required by autonomous-merge)** | Build the `Real` LLM oracle (`Gate.Oracle.Real`, the W-spawned critic/reviewer of `gate-and-toolchain.md` §6) so the factory's own gate is judgement-complete before it merges. | HIGH if skipped under autonomous-merge: merging on a stub-passed gate ships unreviewed code to `main`. HIGH if built prematurely: a large, judgement-quality-sensitive subsystem (the `Real` oracle) on the critical path before any real PR has ever been produced. |

**Coupling rule:** *autonomous-merge (D-DEC-1 B) REQUIRES gate-replication
(D-DEC-2 B).* You may not merge autonomously on a stub-passed or judgement-
absent gate. PR-mode (A/A) lets the `Real` oracle be built **later**, off the
dogfooding critical path. **Recommendation: A/A first.** Build `Gate.Oracle.Real`
as a *parallel* track that graduates the factory toward autonomous-merge — not as
a dogfooding prerequisite.

### D-DEC-3 — Issue scope: which real issues may the factory attempt?

**Discriminating question:** *May the factory attempt* **any** *open tau issue,
or only a* **curated, labelled subset** *(small, well-specified, low-blast-
radius — e.g. a `factory-safe` label)?*

A real coding agent on an arbitrary issue can attempt a sweeping, ambiguous, or
architecture-bearing change. Tau's own rules forbid the coordinator from
improvising architecture (`feedback_arch_consistency_gate`) and require a SPEC
before coordination-heavy code (`spec-before-code.md`).

- **Cost of "any issue":** the agent attempts an underspecified or arch-bearing
  issue, burns tokens, and produces a PR that cannot pass review — or, worse,
  one that *looks* plausible but violates an unstated invariant. Wasted spend +
  reviewer load.
- **Cost of "curated subset":** slower path to "the factory closed a real
  issue"; some human triage cost to label issues.

**Recommendation:** a **curated `factory-safe` label** for the first dogfooding
runs (small, mechanical, well-specified issues), widening only as confidence
grows. Cheap to reverse (remove the label filter); avoids the expensive failure.

### D-DEC-4 — Budget ceiling & token authority before pointing a real agent at real work

**Discriminating question:** *What is the* **hard token / cost / wall-time /
iteration ceiling** *per dogfooding run, and is the* **egress governance chain
active** *before the first real-LLM agent runs?*

A real `ClaudeCode` agent spends real tokens. The arch's egress chain
(`RateLimiter → CircuitBreaker → Budget`) and the engine-`clamp` that **rejects
an infinite budget** (`governance.md` §1–§3) are the structural defense against
runaway spend — but **none of `Egress`, `Policy`, `ActionClassifier` exist in
code yet** (confirmed: the modules are absent; SPEC-FACTORY-GOV is "Draft", issue
"TBD"). Today there is *no structural budget ceiling on a factory agent.*

- **Cost of running without a ceiling:** an agent (or a refine→pivot loop, or a
  5xx-retry storm) burns an unbounded amount of money/quota with no fail-closed
  stop. The arch calls this exact prior failure out (`governance.md` §0).
- **Cost of demanding the full governance plane first:** a large net-new
  subsystem (Egress + Policy + clamp + classifier + lineage) on the critical
  path before the first real PR.

**Recommendation:** a **minimal hard ceiling is a dogfooding prerequisite**
(blocker GOV1) — at least a per-run token/wall-time cap and a kill switch — even
if the full SPEC-FACTORY-GOV plane lands incrementally. Do **not** point a
token-spending agent at real work with no ceiling.

### D-DEC-5 — The head-SHA coordinate model (`[C121-B11]`)

**Discriminating question:** *Should the Unit/gate/merge key on the* **declared
`work_item.hash`** *(today) or on the agent's* **actual reported `head_sha`**
*(`work_ready`)?*

This reads like an engineering default but it is **load-bearing for correctness**
under a real agent (see blocker C1). The arch's §7.2 note
(`control-plane.md`) is explicit: *"U discards `work_ready`'s `head_sha` and keys
`gate_fun`/`merge_fun` on the declared `work_item.hash` … The scripted agent makes
the declared `branch`/`hash` exactly the commit it produces, so … no head-SHA
threading change is needed for the dogfood."* **A real agent cannot pre-declare
the hash of a commit it has not yet authored.** So this is a real decision with a
real cost asymmetry — surfaced here, designed in C1.

- **Cost of keeping declared-hash:** the gate verifies and the merge CAS keys on
  a coordinate that is **not the agent's actual work** — a false-green / wrong-
  diff merge path. Catastrophic under autonomous-merge; a wrong-PR under PR-mode.
- **Cost of threading actual head_sha:** a contract change touching the Unit FSM,
  `UnitDriver`, the gate Request, and the merge map — bounded and mechanical
  once specified, but it crosses a SPEC §4 boundary (SPEC-FACTORY-CORE) so it is
  a spec amendment, not a silent slip.

**Recommendation:** thread the **actual `head_sha`** (the agent is the authority
for what it produced). This is an **ARCH GAP** — see §5, blocker C1.

---

## 3. Blocker inventory (exhaustive, grouped)

Fourteen blockers in five groups: **(A) Agent**, **(C) Coordinate/contract**,
**(T) Target/repo**, **(G) Gate/merge**, **(GOV) Governance**. Each: *what /
why-it-blocks / where / removal / arch-status*.

### Group A — Real coding agent vs canned script

#### A1 — The "coding agent" is a canned shell script

- **What.** `Tau.Factory.Dogfood.Agent.write/1` writes a fixed `/bin/sh` script
  that emits one hardcoded `lib/sandbox.ex` and a fixed `work_ready` frame. The
  worker runs it as `agent_bin` via a `Port`.
- **Why it blocks.** Dogfooding requires a *real* agent that reads an issue,
  reasons, edits files, and commits a non-deterministic diff. The script proves
  the *control plane*, not authorship.
- **Where.** `lib/tau/factory/dogfood/agent.ex`; consumed at
  `lib/tau/factory/worker.ex` (`Port.open({:spawn_executable, agent_bin}, …)`).
- **Removal.** Replace the scripted `agent_bin` with a real agent. The substrate
  exists: `Tau.CodingAgent` (behaviour) + `Tau.CodingAgents.ClaudeCode`
  (subprocess adapter). The work is to make the **Worker's `agent_bin` Port
  contract** and the **`Tau.CodingAgent` stream contract** meet — they are two
  *different* execution models (raw `{:packet,4}` Port emitting a `work_ready`
  frame, vs. an Elixir `Enumerable` of `%CodingAgent.Event{}`). Either: (i) wrap
  `ClaudeCode` behind a small `agent_bin`-shaped shim that drives the adapter and
  emits the D-326 `work_ready` frame on `%Event.Done{}`; or (ii) teach the Worker
  to drive a `Tau.CodingAgent` adapter directly instead of a `Port` to a binary.
- **Arch status.** **PARTIALLY ADDRESSED.** SPEC-CODING-AGENT + the `ClaudeCode`
  adapter are the substrate. But the **Worker↔CodingAgent seam does not exist** —
  the Worker only knows `agent_bin` + `{:packet,4}` Port; the adapter speaks
  `Enumerable`/`Event`. **ARCH GAP:** the bridge between the W fleet's Port model
  and the `Tau.CodingAgent` stream model is unspecified. Needs a shaper pass +
  D-NNN (see §5).

#### A2 — Brief / issue→prompt path

- **What.** The Worker is spawned with a `:brief` string; the scripted agent
  ignores it. A real agent needs the **issue body, the SPEC/AC/D-NNN context, the
  declared scope, and the gating-test paths** turned into a prompt.
- **Why it blocks.** Without a real brief→prompt construction, a real agent has
  nothing to solve. Tau's own memory (`feedback_brief_implementers_with_arch`)
  requires pointing implementers at `docs/arch`, not just SPEC §-refs.
- **Where.** `:brief` flows `UnitDriver.drive/2` → `WorkerSupervisor.spawn/5` →
  `Worker.init/1`; today set by the dogfood task. The `task.prompt` field of
  `Tau.CodingAgent.task` is the target.
- **Removal.** Build a brief/prompt assembler: issue body + linked SPEC/AC/D-NNN
  + declared scope + gating-test paths + arch pointers → `task.prompt`. This is
  the autonomous analogue of the human coordinator's implementer brief.
- **Arch status.** **ARCH GAP.** The arch describes *what* a brief contains
  (`factory-loop.md` draft-PR body; `control-plane.md` U) but there is no
  component that **mechanically assembles** an agent prompt from an issue. Needs
  a shaper pass + D-NNN.

#### A3 — Non-deterministic `work_ready`/diff contract

- **What.** A real agent's output is non-deterministic: it may produce an empty
  diff, a partial fix, a multi-file change, or fail. The D-326 `work_ready`
  contract (`{branch, head_sha}`) was designed for exactly this in-band assertion
  — but the consumers downstream assume the *declared* coordinate (see C1).
- **Why it blocks.** The factory must treat "agent ran but produced nothing" and
  "agent produced a real diff" distinctly (the §3.2.1 D-326 rationale). The
  scripted agent always produces the same real diff; a real one may not.
- **Where.** `lib/tau/factory/worker.ex` (`work_ready_seen?`, the `:no_work_product`
  fail-closed path) — this part is **already correct**; the gap is downstream (C1).
- **Removal.** Lean on the existing D-326 fail-closed `:no_work_product` path for
  empty output; thread the real `head_sha` (C1) for non-empty output; map agent
  failure to the Unit's semantic-failure/refine ladder.
- **Arch status.** **ADDRESSED** for the Port contract (D-326, `worker.ex`); the
  downstream coordinate handling is C1's gap.

### Group C — Coordinate / contract correctness

#### C1 — `[C121-B11]`: the actual `head_sha` is discarded

- **What.** The Unit FSM receives `{:work_ready, worker_id, branch, head_sha}`
  but **discards `head_sha`** (`unit.ex` — `implementing(:info, {:work_ready, …,
  _head_sha}, …)`). It keys `gate_fun`/`merge_fun` on the **pre-declared**
  `data.hash` (`IssueSelector.content_hash/2` = `sha256("N:title")`), and
  `UnitDriver.merge_fun` builds the merge map with that declared `hash` and the
  declared `branch`, never the agent's reported coordinate.
- **Why it blocks.** A real agent's output is **not a pre-known commit**. The
  gate would verify, and the merge CAS would key on, a *fictional* coordinate
  unrelated to what the agent actually authored — a wrong-diff / false-green path
  into merge. The #480/#481 critic flagged this as the first real-world blocker.
  The arch's §7.2 note concedes the dogfood only sidesteps it because the
  *scripted* agent forces declared==actual.
- **Where.** `lib/tau/factory/unit.ex` (`oracle`/`implementing` `work_ready`
  clauses drop `_head_sha`); `lib/tau/factory/unit_driver.ex` (`merge_fun` uses
  `merge_hash`/`branch` from `work_item`, not the reported pair);
  `lib/tau/factory/gate/request.ex` (`hash` field); `merge_authority.ex`
  (`hd_hash`, `assert_all_verdicts_live`, telemetry key on `unit.hash`).
- **Removal.** Thread the agent's reported `head_sha` (and confirmed `branch`)
  from `work_ready` into `data`, and key the gate Request `hash` and the merge
  map on it. The merge `default_build` already operates off `branch`
  (`git checkout unit.branch`), so the *branch* path is partly real; the **`hash`
  coordinate** is the lie. Decide content-hash-of-diff vs HEAD-SHA as the
  canonical key (D-DEC-5).
- **Arch status.** **ARCH GAP.** Crosses a SPEC-FACTORY-CORE §4 boundary
  (`[C121-B11]` is named there as a *deliberate deferral*). The fix is a spec
  amendment + new/clarified D-NNN. Needs a shaper pass (the coordinate-identity
  question — content hash vs HEAD SHA vs both — is a V4 "two-writers/one-truth"
  surface). See §5.

### Group T — Target = the real tau repo

#### T1 — Target is a throwaway sandbox, not real tau

- **What.** The dogfood seeds a fresh mix-project sandbox (`Dogfood.Sandbox.seed/1`)
  and operates entirely within it. Real dogfooding targets the actual tau working
  tree + its real history.
- **Why it blocks.** Definitionally — dogfooding means tau improves tau.
- **Where.** `lib/mix/tasks/tau.factory.dogfood.ex` (`--repo <sandbox>`,
  `Sandbox.seed`); `lib/tau/factory/dogfood/sandbox.ex`.
- **Removal.** Point the factory at the real tau repo as `repo_dir`. This is
  *mostly configuration* — but it forces T2 (isolation discipline on the real
  repo) and interacts with D-DEC-1 (the origin guard).
- **Arch status.** **ADDRESSED in principle** (the factory is repo-dir-parametric;
  `merge-and-integration.md` §5 dogfood note says "the production merge path
  pointed at a sandbox remote" — pointing it elsewhere is the parameter), but see
  T2.

#### T2 — Worktree + `$HOME`-cache isolation on the real repo

- **What.** The fleet allocates per-worker worktrees under the parent repo's
  parent dir (`worker.ex` — `Path.join([Path.dirname(repo_dir), ".worker-wt-#{id}"])`)
  and per-worker HOME-namespace caches (`Worker.Isolation`). On the real tau repo
  with real concurrency and real builds (Burrito, mix, hex), the
  `worktree-discipline.md` invariants (parent-on-`main`, per-agent `XDG_DATA_HOME`,
  capture-before-destroy) become live, not hypothetical.
- **Why it blocks.** A real coding-agent build on the real repo races the shared
  `~/.local/share/.burrito/`, `~/.mix`, `~/.hex` caches (the documented canonical
  offenders) and can corrupt concurrent runs or the developer's own tree.
- **Where.** `lib/tau/factory/worker/isolation.ex`,
  `lib/tau/factory/toolchains/elixir.ex` (`declare_resource_namespace`),
  `worktree-discipline.md`.
- **Removal.** Verify the toolchain's `declare_resource_namespace` covers every
  real-build cache; ensure the factory never runs against the same working tree a
  human is editing (operate on a dedicated clone, not the dev checkout).
- **Arch status.** **ADDRESSED** by `worker-fleet.md` INV-10 + the Elixir
  toolchain's resource-NS declaration + `worktree-discipline.md`. The gap is
  *operational verification on the real repo*, not missing design.

### Group I — Issue source

#### I1 — `IssueSelector` against real `gh issue list` on tau

- **What.** `IssueSelector.select/1` already has a real `default_gh_fun` that
  shells `gh issue list --milestone <m> --state open --json …`. The dogfood
  *overrides* it with a one-shot stub returning the seeded fake issue.
- **Why it blocks.** Real dogfooding must read **real open tau issues**.
- **Where.** `lib/tau/factory/issue_selector.ex` (real path exists);
  `lib/mix/tasks/tau.factory.dogfood.ex` (`gh_fun` stub).
- **Removal.** Drop the stub; pass the real `gh_fun` + a real tau milestone (or
  the `factory-safe` label from D-DEC-3). Mostly removing a test seam.
- **Arch status.** **ADDRESSED.** The real `gh` adapter is implemented and
  Ledger-projected (D-331). Low-risk mechanical change, gated by D-DEC-3.

#### I2 — Issue elaboration / scope declaration / conflict-check on real issues

- **What.** A real issue has no pre-declared scope. The Unit needs
  `declared_scope` (files, codepoints, SPECs, D-NNN, resources) for
  `Scheduler.admit/3` and the 5-clause `ConflictCheck`. Today the dogfood derives
  a trivial scope string; `IssueSelector.pick_work_item` produces a coarse
  `"#{number}: #{title}"` scope.
- **Why it blocks.** Without a real declared scope, the conflict check is vacuous
  and parallel batches are unsafe; the agent has no scope boundary.
- **Where.** `lib/tau/factory/issue_selector.ex` (`pick_work_item`);
  `lib/tau/factory/conflict_check.ex`; `control-plane.md` §2.3 (the scope shape).
- **Removal.** An **issue-elaboration step** that turns an issue into a declared
  `ConflictCheck.scope()` (the arch's full scope map: deps, files, gating_paths,
  codepoints, specs, d_nnn, resources). This is the autonomous analogue of the
  human coordinator's "elaboration brief".
- **Arch status.** **ARCH GAP.** `ConflictCheck.scope()` is fully specified
  (`control-plane.md` §2.3) but **nothing derives it from a real issue**. The
  derivation (especially declared file/codepoint sets) needs a shaper pass +
  D-NNN. See §5.

### Group G — Gate / merge model & safety

#### G1 — The `Real` critic/reviewer oracle is an unimplemented stub

- **What.** `Gate.Oracle.Real.judge/2` returns `:fail` ("LLM worker path lands in
  P5c-3"). The floor `[:mutation, :critic, :reviewer]` therefore cannot pass with
  real judgement; the dogfood pins `oracle: %{critic: :pass, reviewer: :pass}` to
  force a pass.
- **Why it blocks.** Under **autonomous-merge (D-DEC-1 B)** the factory would
  merge on a stub-passed gate — i.e. **with no real review at all**. Under
  **PR-mode (D-DEC-1 A)** it is *not* a blocker (tau's real critic+reviewer do the
  judgement on the PR).
- **Where.** `lib/tau/factory/gate/oracle.ex` (`Real`); `gate-and-toolchain.md`
  §6.
- **Removal.** Build `Gate.Oracle.Real` (spawn a W critic/reviewer, await a
  structured `%OracleVerdict{}`) — **only required for autonomous-merge.**
- **Arch status.** **ADDRESSED (designed, unimplemented).** `gate-and-toolchain.md`
  §6 fully specifies it; SPEC-FACTORY-GATE owns it. The work is implementation,
  not design. **Conditional blocker** — gated by D-DEC-1/D-DEC-2.

#### G2 — Gate-model alignment: factory gate ≠ tau's actual merge gate

- **What.** The factory's `Gate.run` = 3 mechanical gates + 2 oracle halves + the
  toolchain health check. Tau's **actual** merge gate (`factory-loop.md`,
  `.github/workflows/ci.yml`) is critic + reviewer (LLM) + the **full CI matrix**
  (compile-warnings-as-errors, format, credo, dialyzer, the three `mix
  tau.gate.*` CLI gates, the binary smoke tests). The factory's local gate does
  **not** replicate CI.
- **Why it blocks.** A factory PR that passes the factory's gate may still fail
  tau's CI. Under autonomous-merge that lands a red `main`; under PR-mode the PR
  bounces off CI (recoverable but wasteful).
- **Where.** `lib/tau/factory/gate.ex` vs `.github/workflows/ci.yml` +
  `factory-loop.md` "The gate".
- **Removal.** **PR-mode (D-DEC-1 A):** defer — CI runs on the PR; the factory
  need only run a *cheap pre-flight* (compile + the relevant tests) to avoid
  obviously-broken PRs. **Autonomous-merge (B):** the factory must run a CI-
  equivalent locally before merge (a strict superset of `Merge.Health.check`,
  which today is only `mix compile --warnings-as-errors` + `mix test`).
- **Arch status.** **PARTIALLY ADDRESSED.** `merge-and-integration.md` §5 + the
  `Toolchain.lint` descriptor (`gate-and-toolchain.md` §4.1) name the lint/CI
  steps, but the factory's *health check* currently runs only compile+test, not
  the full lint/credo/dialyzer/smoke matrix. **ARCH GAP under autonomous-merge:**
  the relationship between `Merge.Health.check` and tau's full CI matrix needs a
  shaper pass. Under PR-mode it is mostly resolved (CI is authoritative).

#### G3 — Force-push safety on the real remote (the D-359 collision)

- **What.** `MergeAuthority.cas_push` does `git push --force-with-lease` to
  `origin/main`. The dogfood **hard-refuses** any non-local origin (D-359,
  `tau.factory.dogfood.ex` `check_local_origin!`) — so the factory **literally
  cannot operate on real GitHub today.**
- **Why it blocks.** Real dogfooding is on the real remote; the guard forbids it.
  But removing the guard naively = autonomous force-push of real `main`
  (D-DEC-1 B, catastrophic).
- **Where.** `lib/mix/tasks/tau.factory.dogfood.ex` (`check_local_origin!`,
  `non_local_origin?`); `lib/tau/factory/merge_authority.ex` (`cas_push`);
  `governance.md` §4 (`E-DESTRUCTIVE` classification — **unimplemented**, GOV2).
- **Removal.** **PR-mode (D-DEC-1 A):** the terminal action becomes `gh pr create`
  + branch push (a *non-destructive*, reviewable action) — the force-push path is
  **not taken at all**, so D-359 can stay as a guard against accidental
  autonomous-merge. **Autonomous-merge (B):** requires the `ActionClassifier`
  (GOV2) + an explicit, separately-gated operator opt-in + the full real-remote
  escalation/kill model (GOV3).
- **Arch status.** **PARTIALLY ADDRESSED.** D-359 is the *current* safety guard;
  `governance.md` §4 designs the `E-DESTRUCTIVE` classifier but it is
  **unimplemented**. **ARCH GAP:** the **PR-mode seam itself does not exist** in
  the arch — the Unit's terminal is `awaiting_merge → merged` (force-push), with
  no `awaiting_pr → pr_opened` alternative. Adding PR-mode is a new Unit terminal
  + a new MergeAuthority-or-sibling action. Needs a shaper pass + D-NNN. See §5.

#### G4 — `Merge.Health.check` is narrower than tau's `main` health bar

- **What.** `Merge.Health.check` runs `mix compile --warnings-as-errors` + `mix
  test` (`merge_authority.ex` `default_build`). Tau's `main` health bar
  (`factory-loop.md` 8d, CI) is a strict superset (format, credo, dialyzer,
  gate CLIs, binary smoke).
- **Why it blocks.** A "green health" the factory reports is weaker than tau's
  real green. Under autonomous-merge a narrow-green tip can still be CI-red.
- **Where.** `lib/tau/factory/merge/health.ex`; `lib/tau/factory/toolchains/elixir.ex`
  (`lint` descriptor names the full set but health doesn't run it).
- **Removal.** Widen `Merge.Health.check` (or the build task) to run the full
  `Toolchain.lint` descriptor steps — **only strictly required under autonomous-
  merge**; under PR-mode CI is the backstop.
- **Arch status.** **PARTIALLY ADDRESSED** (the `lint` descriptor exists;
  health doesn't invoke it). Conditional on D-DEC-1.

### Group GOV — Governance / cost / escalation

#### GOV1 — No budget ceiling on a token-spending agent

- **What.** `Budget.Owner` (ETS snapshot + Ledger truth) **exists**, but the
  **`Egress` chokepoint, `Policy` plane, and engine-`clamp` do NOT** (modules
  absent; SPEC-FACTORY-GOV "Draft", issue TBD). No outbound provider call from a
  factory agent currently passes through a rate-limit→breaker→budget chain, and
  no `clamp` rejects an infinite budget.
- **Why it blocks.** A real `ClaudeCode` agent spends real money. Without a
  structural ceiling, a refine/pivot loop or a 5xx-retry storm burns unbounded
  spend — the exact prior failure `governance.md` §0 names.
- **Where.** `lib/tau/factory/budget/owner.ex` (exists); **missing**
  `lib/tau/factory/egress.ex`, `policy.ex`, `action_classifier.ex`;
  `SPEC-FACTORY-GOV.md`; `governance.md` §1–§3.
- **Removal.** At minimum, wire a **hard per-run ceiling** (token/cost/wall-time/
  iteration) and route the agent's provider calls through `Budget.admit`. Full
  fix is the SPEC-FACTORY-GOV egress chain.
- **Arch status.** **ADDRESSED in design, UNIMPLEMENTED in code.**
  `governance.md` + SPEC-FACTORY-GOV (Draft) fully specify it. The blocker is
  that **none of it is built** and SPEC-FACTORY-GOV has no issue yet. A minimal
  ceiling is a **dogfooding prerequisite** (D-DEC-4).

#### GOV2 — `ActionClassifier` (E-DESTRUCTIVE) is unimplemented

- **What.** `governance.md` §4's pure denylist classifier (`:force_push`,
  `:history_rewrite`, `:release`, …) that denies destructive actions at the
  boundary does **not exist** (`action_classifier.ex` absent).
- **Why it blocks.** It is the structural guard that *would* prevent an
  autonomous force-push on the real remote (D-DEC-1 B). Without it, only the
  D-359 origin guard (a coarse precondition) stands between the factory and a
  real-`main` force-push.
- **Where.** missing `lib/tau/factory/action_classifier.ex`; `governance.md` §4;
  `merge-and-integration.md` §3.
- **Removal.** Implement the pure classifier; call it before any `git push` M
  issues. **Required for autonomous-merge; optional under PR-mode** (PR-mode's
  terminal action is non-destructive).
- **Arch status.** **ADDRESSED in design, UNIMPLEMENTED.** Conditional on D-DEC-1.

#### GOV3 — Escalation / human-in-the-loop / kill switch on the real codebase

- **What.** The escalation set E (`Escalation.classify/1` — exists) + the kill
  switch (`KillSwitch` — exists, `.claude/STOP-FACTORY` sentinel) + the
  reporting cadence form the safety circuit. On the **real** codebase the
  human-in-the-loop and escalation surfaces (E-BUDGET, E-DESTRUCTIVE, E-RED-MAIN,
  E-AMBIGUITY) must be *live and observed*, not just present.
- **Why it blocks.** A factory operating on real tau must be stoppable and must
  surface every non-progress reason to an operator — the §1.4 totality property
  is the whole-system safety claim.
- **Where.** `lib/tau/factory/escalation.ex`, `lib/tau/factory/kill_switch.ex`
  (both exist); `control-plane.md` §1.3–1.5, §7; `governance.md` §6–§7.
- **Removal.** Verify the kill switch + escalation reporting are wired to a real
  operator surface for the dogfooding run (a place the operator actually watches);
  confirm E-DESTRUCTIVE routing once GOV2 lands; confirm E-BUDGET once GOV1 lands.
- **Arch status.** **ADDRESSED** (classify + kill switch implemented;
  `E-DESTRUCTIVE`/`E-BUDGET` routing depends on GOV2/GOV1). Operational wiring +
  verification, not missing design.

#### GOV4 — Timeouts for real (long, variable) agent runs

- **What.** Default Unit per-state `:state_timeout` is 30 s (`unit.ex`); the
  dogfood widens to 300 s (D-358). A real `ClaudeCode` run is long *and variable*
  — a fixed widened timeout either trips on a slow-but-healthy agent (false
  E-RETRY-EXHAUSTED) or masks a genuinely-wedged one.
- **Why it blocks.** The §3.2 liveness guard (timeout → retry ladder) must be
  tuned so a real run is bounded without spurious escalation. The arch's preferred
  mechanism is a **heartbeat/progress watchdog** (`control-plane.md` §3.2 guard 2,
  `worker-fleet.md`), not a fixed timeout — but the dogfood uses a fixed timeout.
- **Where.** `lib/tau/factory/unit.ex` (`@default_state_timeout_ms`, `:timeouts`);
  `lib/tau/factory/fleet/watchdog.ex` (heartbeat watchdog — present);
  `control-plane.md` §3.2; D-358.
- **Removal.** Use the **progress-heartbeat watchdog** (the agent emits progress;
  absence beyond a threshold synthesizes `worker_stalled`) rather than a fixed
  wall-clock timeout, so a long-but-live agent is not killed. Wire the `ClaudeCode`
  adapter's streaming events to heartbeats.
- **Arch status.** **PARTIALLY ADDRESSED.** The watchdog + heartbeat design exists
  (`control-plane.md` §3.2; `fleet/watchdog.ex`); the **bridge from `ClaudeCode`
  stream events to worker heartbeats does not.** Couples to A1. **ARCH GAP** on the
  heartbeat-source bridge. See §5.

---

## 4. Phased, dependency-ordered removal roadmap

Phases are ordered by dependency. **Phase 0 (decisions) gates everything.**
SPEC-first (coordination-heavy) items are marked **[SPEC]**; mechanical items
**[mech]**. Suggested milestone/issue breakdown follows.

### Phase 0 — Decisions (no code; blocks all downstream)

Resolve **D-DEC-1** (merge model), **D-DEC-2** (gate model), **D-DEC-3** (issue
scope), **D-DEC-4** (budget ceiling), **D-DEC-5** (head-SHA coordinate). The
recommended set — **PR-mode + defer-gate + curated `factory-safe` label +
minimal hard ceiling + thread-actual-head_sha** — is the cheap-to-reverse shape;
adopt or override before any implementation. **The rest of this roadmap assumes
PR-mode** (the autonomous-merge branches are noted but not on the critical path).

### Phase 1 — Coordinate correctness + agent bridge (the substrate)

These are prerequisites for *any* real agent producing a *correctly-keyed* PR.

1. **C1 — thread actual `head_sha`** **[SPEC]** (SPEC-FACTORY-CORE amend, `[C121-B11]`).
   *Unblocks:* every real-agent path (gate/merge key on real work). *ARCH GAP →
   shaper pass first.*
2. **A1 — Worker↔CodingAgent bridge** **[SPEC]** (SPEC-CODING-AGENT × SPEC-
   FACTORY-FLEET). Wire `ClaudeCode` as the worker's agent, emitting the D-326
   `work_ready` frame. *Unblocks:* A2, A3, GOV4. *ARCH GAP → shaper pass first.*
3. **A2 — issue→prompt assembler** **[SPEC]**. *Depends on:* I2 (scope) for the
   scope portion of the prompt. *ARCH GAP.*
4. **GOV4 — heartbeat-driven timeout** **[mech]** once A1 lands (bridge stream
   events → heartbeats). *Depends on:* A1.

### Phase 2 — Real issue intake (replace the seeded fixture)

5. **I1 — real `gh issue list` on tau** **[mech]** (drop the dogfood stub;
   `factory-safe` label per D-DEC-3). *Low risk.*
6. **I2 — issue→declared-scope elaboration** **[SPEC]**. *Unblocks:* A2, safe
   parallelism. *ARCH GAP → shaper pass.*

### Phase 3 — Budget ceiling (prerequisite before real spend)

7. **GOV1 — minimal hard budget ceiling** **[SPEC]** (SPEC-FACTORY-GOV — needs an
   issue; file it). At minimum: route agent provider calls through `Budget.admit`
   + a per-run token/wall-time cap + `clamp` rejecting infinite budgets.
8. **GOV3 — escalation + kill-switch operator wiring** **[mech]** (verify live for
   the real run; both modules exist).

### Phase 4 — Real target + PR-mode terminal (operate on real tau)

9. **T1/T2 — point at a dedicated real-tau clone** **[mech]** with full
   worktree + cache isolation verified (never the dev checkout).
10. **G3 — PR-mode terminal seam** **[SPEC]** (new Unit terminal `awaiting_pr →
    :pr_opened`; terminal action = `gh pr create` + branch push, NOT force-push).
    *Keeps D-359 as the autonomous-merge guard.* *ARCH GAP → shaper pass.*
11. **G2 (pre-flight) — cheap local pre-flight** **[mech]** (compile + relevant
    tests) so the factory doesn't open obviously-broken PRs; CI is authoritative.

### Phase 5 — The dogfooding run (AC-10) + parallel autonomous-merge track

12. **AC-10 run:** point the factory at real tau, a `factory-safe` issue, the real
    `ClaudeCode` agent, PR-mode terminal, budget ceiling active → observe a **real
    PR** that passes tau's real critic+reviewer+CI gate and is merged (by the human
    gate). *This is dogfooding under PR-mode.*

**Parallel/later track — graduation to autonomous-merge (only if D-DEC-1 → B):**
G1 (`Real` oracle), GOV2 (`ActionClassifier`), G2/G4 (CI-equivalent local gate +
full health), and an explicit operator opt-in past D-359. Each independently
SPEC'd; **not on the PR-mode dogfooding critical path.**

### Suggested milestone / issue breakdown

- **Milestone "Dogfooding — coordinate & agent substrate" (Phase 1):** C1, A1,
  A2, GOV4 — each its own issue; C1 and A1 carry a SPEC amendment.
- **Milestone "Dogfooding — real intake" (Phase 2):** I1, I2.
- **Milestone "Dogfooding — governance floor" (Phase 3):** GOV1 (file the
  SPEC-FACTORY-GOV issue), GOV3 verification.
- **Milestone "Dogfooding — real target & PR-mode" (Phase 4):** T1/T2, G3, G2-preflight.
- **Milestone "Dogfooding — AC-10 run" (Phase 5):** the capstone run.
- **Milestone "Autonomous-merge graduation" (later, conditional):** G1, GOV2,
  G2-full, G4, D-359 opt-in.

---

## 5. Arch coverage — ADDRESSED vs ARCH GAP

### Already covered by existing arch (cite it)

| Blocker | Covered by |
|---|---|
| A3 (Port work_ready/no-work-product) | D-326, `worker.ex`; `control-plane.md` §3.2.1 |
| I1 (real `gh` adapter) | `IssueSelector` real `gh_fun`, D-331; `control-plane.md` §2 |
| T1/T2 (repo-dir param + isolation) | `worker-fleet.md` INV-10; Elixir toolchain `declare_resource_namespace`; `worktree-discipline.md` |
| G1 (Real oracle design) | `gate-and-toolchain.md` §6; SPEC-FACTORY-GATE *(designed, unimplemented)* |
| GOV1/GOV2 (egress + classifier design) | `governance.md` §1–§4; SPEC-FACTORY-GOV (Draft) *(designed, unimplemented)* |
| GOV3 (escalation + kill switch) | `Escalation.classify`, `KillSwitch`; `control-plane.md` §1.3–1.5 |

### Genuine ARCH GAPS — need a solution-shaping pass + a new D-NNN BEFORE code

1. **C1 — head-SHA coordinate identity (`[C121-B11]`).** The canonical merge/gate
   key (declared content-hash vs actual HEAD SHA vs content-hash-of-actual-diff)
   is a V4 "two-writers/one-truth" question the arch *deferred*. SPEC-FACTORY-CORE
   §4 amendment + a clarified D-NNN.
2. **A1 — Worker↔CodingAgent bridge.** The W fleet's `agent_bin`+`{:packet,4}`
   Port model and the `Tau.CodingAgent` `Enumerable`/`Event` model are two
   different execution shapes with **no specified bridge**. New D-NNN spanning
   SPEC-FACTORY-FLEET × SPEC-CODING-AGENT.
3. **A2 — issue→prompt assembler.** No component mechanically turns an
   issue+SPEC+scope+arch into an agent prompt. New D-NNN (likely SPEC-FACTORY-CORE
   or a new SPEC).
4. **I2 — issue→declared-scope elaboration.** `ConflictCheck.scope()` is fully
   specified but **nothing derives it from a real issue**; deriving declared
   file/codepoint sets autonomously is non-trivial and safety-relevant (it gates
   parallelism). New D-NNN.
5. **G3 — PR-mode terminal seam.** The Unit terminal is `awaiting_merge → merged`
   (force-push) with **no `awaiting_pr → :pr_opened` alternative.** PR-mode is a
   new terminal + a new (non-destructive) terminal action. New D-NNN
   (SPEC-FACTORY-CORE + SPEC-FACTORY-MERGE). *This is the highest-leverage gap —
   it is the seam D-DEC-1 (PR-mode) requires.*
6. **G2 / G4 — factory-gate ↔ tau-CI relationship (autonomous-merge only).** Under
   autonomous-merge, the relationship between `Merge.Health.check` and tau's full
   CI matrix (and whether the factory replicates CI locally) is unspecified. New
   D-NNN — but **only on the autonomous-merge track**, not PR-mode.
7. **GOV4 — heartbeat-source bridge.** The watchdog + heartbeat design exists but
   the bridge from `ClaudeCode` stream events to worker heartbeats does not. New
   D-NNN (couples to A1).

**Discipline (tau memory `feedback_arch_consistency_gate`):** for each ARCH GAP,
STOP and run a solution-shaping architecture pass producing a D-NNN **before**
any implementer is briefed. Do not improvise architecture in an implementation PR.

---

## 6. Summary

- **Blockers:** 14 (A1, A2, A3, C1, T1, T2, I1, I2, G1, G2, G3, G4, GOV1, GOV2,
  GOV3, GOV4 — grouped; A3/T1/I1/GOV3 are largely already-addressed or
  operational-verification).
- **The plan is gated by 5 product decisions** — above all D-DEC-1 (PR-mode vs
  autonomous-merge), whose cost asymmetry is maximal and one-directional. The
  recommended cheap-to-reverse shape (PR-mode + defer-gate) **dissolves or
  defers** G1, G2-full, G4, GOV2, and the autonomous force-push hazard.
- **7 genuine ARCH GAPS** need a shaper pass + D-NNN before code; the rest are
  designed-but-unimplemented or mechanical/operational.
