# Software architecture — Gate (G) & Toolchain seam

This file details two of the components mapped abstractly in
`../03-system-architecture/system-architecture.md` (§1 G, §1 Toolchain) onto
concrete Elixir/OTP, under the process-placement decisions already fixed in
`supervision-tree.md` (Step 0–1: G is a **transient** `Task.async_stream` fan-out
under `Task.Supervisor GateTasks`, **not** a process; the Toolchain is a
**behaviour** whose adapters return data, and the engine executes). It is the
single highest-risk surface in the factory — gate-gaming
(`../01-research/prior-art.md` §3: ImpossibleBench; frontier models cheat up to
~76% and *more* as they strengthen) — and the realization of the polyglot
constraint **D-S2** (the Toolchain seam). Cross-refs: `worker-fleet.md` (W
isolation + the engine-side subprocess execution), `durable-spine.md` (L, the
append-only verdict log), `control-plane.md` (U/S/K), `governance.md` (Policy
clamps, HR-8).

The governing prior-art finding (`prior-art.md` §3, Cluster B): **an LLM judge
alone is insufficient.** Every claim in this file routes back to that: the
judgement oracles (critic, reviewer) *back* the mechanical gates; they never
replace them.

---

## 1. G — gate orchestration as a bounded fan-out (transient, not a process)

A gate run is a **bounded fan-out of known work over a single pass, then a
fold** — the canonical `Task.async_stream` case, explicitly **not**
Broadway/GenStage (`supervision-tree.md` Step 0–1; research OTP §6: Broadway only
at a genuinely *unbounded* intake boundary; the gate's inputs are fixed at call
time). The gate holds **no state between runs**: it is invoked per `(unit,
hash)`, computes, appends its verdict to L, and dies. There is no `Gate`
GenServer (anti-pattern #1: a process that only namespaces functions).

```elixir
defmodule Tau.Factory.Gate do
  @moduledoc "Transient gate run. Bounded fan-out; no held state."

  @doc """
  Run the full gate for one (unit, hash) over `req`. Returns a structured
  verdict. The caller (U FSM) appends it to L append-only (HR-2); G never
  mutates a prior verdict.
  """
  @spec run(Tau.Factory.Gate.Request.t()) :: Tau.Factory.Gate.Verdict.t()
  def run(%Request{} = req) do
    # The halves: 3 mechanical (pure / engine-executed) + 2 judgement oracles.
    # gate_floor/0 returns the engine-fixed, non-shrinkable subset (HR-8).
    halves = compose(req.policy_pin)          # manifest pinned at admission (HR-8)

    results =
      Task.Supervisor.async_stream_nolink(
        Tau.Factory.GateTasks,
        halves,
        fn half -> {half.id, run_half(half, req)} end,
        max_concurrency: req.policy_pin.gate_concurrency,  # BOUNDED
        timeout: req.policy_pin.gate_timeout,
        on_timeout: :kill_task,
        ordered: false
      )
      |> Enum.map(fn {:ok, kv} -> kv end)
      |> Map.new()

    Verdict.fold(results)   # PASS iff every half PASS; floor halves mandatory
  end

  # The gate floor is engine-fixed; Policy may ADD halves, never remove a floor
  # member (HR-8, INV-1/INV-7). Enforced in `compose/1`, not trusted from policy.
  @gate_floor [:mutation, :critic, :reviewer]
  def gate_floor, do: @gate_floor
end
```

**Why transient.** Organizing the gate as a long-lived process would add a
bottleneck and a failure domain for zero runtime gain (OTP anti-pattern #1/#3).
The fan-out's bound (`max_concurrency`) is the back-pressure; `async_stream` over
`Task.Supervisor.async_stream_nolink` gives crash isolation (a critic worker
crash does not take the gate run with it — it surfaces as `{:exit, reason}` for
that half, which folds to `FAIL`, **not** a coordinator crash; INV-17).

**Verdict is data; the floor is fixed.** `Verdict.fold/1` PASSes iff **all**
halves PASS, and `compose/1` guarantees the floor `{mutation, critic, reviewer}`
is always present regardless of Policy (HR-8; `governance.md`). A gate-green
verdict is content-keyed to `hash(diff)` (INV-1) and **revocable** (HR-2): a
later masking/incomplete-fix/challenge finding appends a *superseding revoke* to
L; it never edits the verdict in place. The merge CAS in M reads the **latest**
status for `hash(d)` (`supervision-tree.md` Step 4; INV-2, FC-4).

**Telemetry.** `[:tau, :factory, :gate, :run, :start | :stop | :exception]`
wraps the whole run; one `[:tau, :factory, :gate, :half, …]` span per half,
tagged `half: <id>`, `unit`, `hash`, `verdict` (NFR-OBS-COVERAGE = 100%; §8).

---

## 2. The three mechanical gates — pure functions (properties before examples)

The three mechanical gates are **plain modules of pure functions** over the diff,
the PR body, and the declared gating-test **path set** (`supervision-tree.md`
Step 7; INV-24 #6 demands properties before examples for invariant-bearing
modules). They are **path-based throughout** (INV-6): the test/production
boundary is the *declared gating-test path set* frozen at scope-freeze — **never
commit attribution** — so the gates survive a refine-cycle rebase (HR survives
rebase). Property statements below are the load-bearing specification; examples
are derived.

### 2.1 `Tau.Factory.Gate.AcLinkage`

Every `AC-N` / `D-NNN` token in the PR body's **acceptance section** must appear
in a gating-test name or `@tag`; meta-ACs (`AC-N (meta)`) are exempt.

```elixir
defmodule Tau.Factory.Gate.AcLinkage do
  @spec check(pr_body :: String.t(), gating_tests :: [TestMeta.t()]) ::
          {:pass, []} | {:fail, [missing :: token()]}
  def check(pr_body, gating_tests), do: ...
end
```

**Properties** (`StreamData`):

- **P-AC1 (soundness).** For any acceptance section `A` and gating-test set `T`:
  `check(A, T) = {:pass, []}` ⟺ every non-meta token in `tokens(A)` occurs in
  some `name(t) ∪ tags(t)`, `t ∈ T`. (∀ token ∈ claims ⇒ linked.)
- **P-AC2 (scope-tightness).** Tokens appearing **only outside** the acceptance
  section (Background prose) are context, never claims:
  `check(A, T)` ignores `tokens(body) \ tokens(A)`.
- **P-AC3 (meta-exemption).** A token tagged `(meta)` in `A` is never reported
  missing: `meta(tok) ⇒ tok ∉ second(check(A, T))`.
- **P-AC4 (monotone in tests).** Adding a gating test never turns a `:pass` into
  a `:fail`: `check(A, T) = :pass ⇒ check(A, T ∪ {t}) = :pass`.

### 2.2 `Tau.Factory.Gate.Masking` (detection-only)

Scan the diff for deleted/weakened assertions and for **any implementer edit to a
declared gating-test path** (INV-6). Detection-only: every hit is surfaced to the
**critic** as a mandatory review item — there is no self-authored bypass tag.

```elixir
defmodule Tau.Factory.Gate.Masking do
  @spec scan(diff :: Diff.t(), gating_paths :: MapSet.t(path())) ::
          {:clean | :flagged, [Finding.t()]}
  def scan(diff, gating_paths), do: ...
end
```

**Properties:**

- **P-MK1 (assertion-deletion detection).** Any hunk deleting/weakening an
  assertion (`-  assert`, `-  refute`, or an assertion replaced by a weaker
  predicate) yields a `Finding`. (∀ deleted assertion ⇒ flagged.)
- **P-MK2 (path-violation detection).** Any diff hunk whose path ∈ `gating_paths`
  yields a `Finding`, **independent of who authored the commit** (path-based, not
  attribution-based; INV-6). This is the property that survives rebase.
- **P-MK3 (detection-only / no verdict).** `scan` never returns PASS/FAIL — only
  `{:clean | :flagged, findings}`. The verdict is the **critic's**, on the
  surfaced findings (`prior-art.md` §3: an implementer edit to a gating-test path
  is a challenge-protocol violation; the human-empty loop routes it to the
  oracle, not to the implementer's own say-so).
- **P-MK4 (rebase-invariance).** For diffs `d`, `d'` that differ only by base
  commit (a rebase) with identical content hunks: `scan(d, P) = scan(d', P)`.

### 2.3 `Tau.Factory.Gate.Mutation`

The non-vacuity check (INV-7): revert **everything except** the declared
gating-test paths to the merge-base, run the gating tests, assert ≥1 fails.

```elixir
defmodule Tau.Factory.Gate.Mutation do
  @doc """
  PURE planning: produce the reverted-tree plan + the gating-test invocation.
  Execution is the ENGINE's job (HR-3, §3) — this module never runs a test
  nor returns a pass/fail. It returns the plan the engine executes and the
  predicate the engine applies to the engine-parsed artifact.
  """
  @spec plan(merge_base :: oid(), gating_paths :: MapSet.t(path())) ::
          Tau.Factory.Mutation.Plan.t()
  def plan(merge_base, gating_paths), do: ...

  @doc "Pure predicate over the engine-parsed structured report."
  @spec judge(report :: Tau.Toolchain.TestReport.t()) ::
          {:pass, killed :: [test_id()]} | {:fail, :no_test_failed} | {:na, reason()}
  def judge(report) do
    case Enum.filter(report.cases, & &1.status == :failed) do
      [] -> {:fail, :no_test_failed}     # vacuous suite — INV-7 violated
      failed -> {:pass, Enum.map(failed, & &1.id)}
    end
  end
end
```

**Properties:**

- **P-MU1 (non-vacuity ⇒ pass).** `judge(report)` is `{:pass, _}` ⟺ `report` has
  ≥1 `:failed` case. A suite that passes wholesale against the reverted
  (production-absent) tree is `:fail` — the vacuous-test hole closed
  (NFR-GAME-RESISTANCE = 0; `prior-art.md` §3 mutation-testing).
- **P-MU2 (boundary = declared paths).** `plan/2` reverts exactly
  `tracked_paths \ gating_paths` to `merge_base` and keeps `gating_paths` at the
  test-author's committed state. The boundary is the **path set**, not commit
  attribution (INV-6), so a refine rebase does not move it.
- **P-MU3 (project-creation N/A).** If every gating path's nearest-ancestor build
  manifest is absent at `merge_base` (the whole sub-project is PR-created),
  `judge` returns `{:na, :project_created}` and the half PASSes — no
  pre-implementer production exists to revert.
- **P-MU4 (purity).** `plan/2` and `judge/1` perform **no I/O**. All subprocess
  execution is the engine's (§3); these functions are referentially transparent
  and property-testable in isolation.

---

## 3. HR-3 — the engine owns test execution (the polyglot-critical fix)

**The hole (FC-5, `synthesis.md` HR-3, volatility-split headline).** Under D-S2
the engine is language-agnostic and *cannot itself know how to run a Rust/JS/Go
test suite* — only the per-language Toolchain adapter does. The **naïve** design
therefore asks the adapter to run the mutation test and report pass/fail. That is
**circular**: the adversary-suspect adapter judges its own mutation result, so a
malicious or merely buggy adapter fakes the mutation PASS, defeating INV-7 and
NFR-GAME-RESISTANCE entirely. The judgement sits on the **untrusted** side.

**The fix — split invocation from judgement; keep judgement on the trusted side.**

1. **Adapter → declarative descriptor only.** The adapter returns *how to invoke*
   the runner and *the machine-readable report format it emits* (JUnit-XML /
   TAP-class). It returns **no verdict** — not even "tests ran".
2. **Engine → execution + parsing + judgement.** The trusted engine runs the
   subprocess itself, in a **host-allocated isolated workspace** (`worker-fleet.md`;
   INV-10), via a `Port`, captures the artifact, **parses it itself**, and applies
   the pure predicate `Tau.Factory.Gate.Mutation.judge/1` (§2.3). The adapter
   never touches the verdict path.
3. **Cross-check (the second lock).** Not only "≥1 test failed on the reverted
   tree" — the engine asserts the **specific failing test ids** from the reverted
   run appear **passing** in the green *real* run for the same `hash`. A faked
   report cannot satisfy both a structurally-valid failing artifact on the
   reverted tree **and** a matching passing id on the real tree, because the
   engine — not the adapter — produced and parsed both.

```elixir
# ENGINE side — trusted. The adapter is consulted only for the recipe.
defmodule Tau.Factory.Engine.TestRun do
  @doc """
  Run a toolchain test descriptor in an isolated workspace and return the
  ENGINE-parsed structured report. The adapter supplied only `descriptor`
  (argv + report format + artifact path). Judgement is NOT delegated.
  """
  @spec execute(Tau.Toolchain.TestDescriptor.t(), workspace :: Path.t()) ::
          {:ok, Tau.Toolchain.TestReport.t()} | {:error, Tau.Toolchain.RunError.t()}
  def execute(%TestDescriptor{argv: argv, env: env, report: fmt, artifact: rel}, ws) do
    port =
      Port.open({:spawn_executable, System.find_executable(hd(argv))},
        [:binary, :exit_status, args: tl(argv), cd: ws, env: scrub(env)])

    case drain(port) do
      {:exit, _code} ->
        # The ENGINE reads + parses the artifact the subprocess wrote.
        # `fmt` selects a TRUSTED engine-side parser (JUnit | TAP | …),
        # NOT an adapter callback — the adapter cannot inject a parser.
        Path.join(ws, rel)
        |> File.read!()
        |> Tau.Toolchain.ReportParser.parse(fmt)   # engine-owned, total
        |> then(&{:ok, &1})

      {:crash, reason} ->
        {:error, %RunError{reason: reason}}        # → half FAILs; not a fake pass
    end
  end
end
```

**The mutation gate end-to-end (engine-executes sequence):**

```
U → G.run(req)
      └─ half :mutation
           1. plan = Gate.Mutation.plan(merge_base, gating_paths)        [PURE]
           2. engine reverts tree-minus-gating-paths to merge_base       [ENGINE/git]
           3. desc = Toolchain.<lang>.test_descriptor(unit_recipe)       [ADAPTER → data only]
           4. {:ok, rev_report} = Engine.TestRun.execute(desc, iso_ws)   [ENGINE runs + parses]
           5. {:pass, killed_ids} = Gate.Mutation.judge(rev_report)      [PURE]
           6. {:ok, real_report}  = Engine.TestRun.execute(desc, green_ws)[ENGINE, real tree]
           7. assert killed_ids ⊆ passing_ids(real_report)               [ENGINE cross-check]
           8. verdict half :mutation = PASS  iff 5 ∧ 7                    [ENGINE]
```

**What this moves to the trusted side.** Not just *invocation* (running argv) but
**judgement** — parsing the artifact and deciding pass/fail. The adapter's entire
surface collapses to *advisory data* (a recipe + a format tag). It is structurally
impossible for the adapter to (a) assert "tests passed", (b) choose the parser, or
(c) see the green-run ids it would need to forge the cross-check — closing FC-5.
The cost (D-S2) is that the engine must ship a trusted parser per report **format**
(JUnit, TAP) — a small, finite, format-keyed set — rather than per **language**;
many languages share JUnit-XML, so the parser set is far smaller than the adapter
set.

---

## 4. `Tau.Factory.Toolchain` behaviour — the D-S2 polyglot seam

The extensibility seam is a **behaviour** (OTP non-negotiable #2: extensibility
seams are behaviours; pattern-match on atoms/structs — never string-keyed
dispatch). Every callback returns a **declarative recipe + report format**, never
a verdict (HR-3) and never a side-effecting run. The host (G executes via the
engine; W consumes the resource declaration for isolation) treats all adapter
output as **advisory data, never control**.

```elixir
defmodule Tau.Factory.Toolchain do
  @moduledoc """
  Per-language toolchain adapter (D-S2). Adapters DESCRIBE; the engine EXECUTES
  and JUDGES (HR-3). Every callback returns a declarative struct — argv, env,
  and the machine-readable report format — NOT a result and NOT a verdict.
  Host-enforced: adapter output is advisory data, never control. A buggy or
  adversarial adapter CANNOT bypass the gate floor (§1, HR-8), the merge
  serialization (M, INV-3), or the isolation boundary (W, INV-10).
  """

  @type recipe :: %{argv: [String.t()], env: %{String.t() => String.t()}}

  # --- build & deps (recipes; engine runs them in an isolated workspace) ---
  @callback install_deps(ctx :: Ctx.t()) :: recipe()
  @callback build(ctx :: Ctx.t()) :: recipe()
  @callback package(ctx :: Ctx.t()) :: recipe()

  # --- test & mutation: recipe + the report FORMAT the engine will parse ---
  @callback test_descriptor(ctx :: Ctx.t()) :: Tau.Toolchain.TestDescriptor.t()
  @callback mutation_descriptor(ctx :: Ctx.t()) :: Tau.Toolchain.TestDescriptor.t()

  # --- lint/compile/typecheck for mechanized INV-24 (§5, HR-6) -------------
  @callback lint(ctx :: Ctx.t()) :: Tau.Toolchain.LintDescriptor.t()

  # --- resource namespace consumed by W for INV-10 isolation --------------
  @doc """
  The COMPLETE set of mutable paths this toolchain touches OUTSIDE the git
  checkout (HOME-namespace caches, XDG dirs, per-language download caches).
  W allocates a per-worker namespace over exactly these (INV-10). Declarative
  data: W enforces isolation; the adapter cannot opt out.
  """
  @callback declare_resource_namespace(ctx :: Ctx.t()) ::
              [Tau.Toolchain.ResourceNS.t()]
end
```

`TestDescriptor` carries `{argv, env, report: :junit | :tap | …, artifact:
rel_path}` — the engine selects a **trusted engine-side parser** by the `report`
tag (§3); the adapter never supplies a parser.

### 4.1 Bootstrap / self-host adapter (Elixir)

```elixir
defmodule Tau.Factory.Toolchain.Elixir do
  @behaviour Tau.Factory.Toolchain

  @impl true
  def install_deps(_ctx), do: %{argv: ~w(mix deps.get), env: %{}}
  @impl true
  def build(_ctx), do: %{argv: ~w(mix compile --warnings-as-errors), env: %{}}

  @impl true
  def test_descriptor(_ctx) do
    %Tau.Toolchain.TestDescriptor{
      # JUnit emitter (e.g. junit_formatter) → engine-parseable artifact.
      argv: ~w(mix test --formatter JUnitFormatter),
      env: %{"MIX_ENV" => "test"},
      report: :junit,
      artifact: "_build/test/lib/tau/test-junit-report.xml"
    }
  end

  @impl true
  def mutation_descriptor(ctx),
    do: %{test_descriptor(ctx) | argv: ~w(mix test --only gating --formatter JUnitFormatter)}

  @impl true
  def lint(_ctx) do
    %Tau.Toolchain.LintDescriptor{
      steps: [
        %{argv: ~w(mix compile --warnings-as-errors), report: :exit_status},
        %{argv: ~w(mix format --check-formatted), report: :exit_status},
        %{argv: ~w(mix credo --strict), report: :exit_status},
        %{argv: ~w(mix dialyzer), report: :exit_status}
      ]
    }
  end

  @impl true
  def declare_resource_namespace(_ctx) do
    [
      %Tau.Toolchain.ResourceNS{kind: :xdg_data, var: "XDG_DATA_HOME"},   # Burrito unpack cache
      %Tau.Toolchain.ResourceNS{kind: :env, var: "MIX_HOME"},
      %Tau.Toolchain.ResourceNS{kind: :env, var: "HEX_HOME"},
      %Tau.Toolchain.ResourceNS{kind: :dir, path: "~/.cache/rebar3"}
    ]
  end
end
```

### 4.2 A second adapter (polyglot generality — Node/JS)

```elixir
defmodule Tau.Factory.Toolchain.Node do
  @behaviour Tau.Factory.Toolchain

  @impl true
  def install_deps(_ctx), do: %{argv: ~w(npm ci), env: %{}}
  @impl true
  def build(_ctx), do: %{argv: ~w(npm run build), env: %{}}

  @impl true
  def test_descriptor(_ctx) do
    %Tau.Toolchain.TestDescriptor{
      argv: ~w(npx jest --ci --reporters=jest-junit),
      env: %{"JEST_JUNIT_OUTPUT_FILE" => "reports/junit.xml"},
      report: :junit,                    # SAME engine parser as Elixir → §3 cost is bounded
      artifact: "reports/junit.xml"
    }
  end

  @impl true
  def mutation_descriptor(ctx),
    do: %{test_descriptor(ctx) | argv: ~w(npx jest --ci -t gating --reporters=jest-junit)}

  @impl true
  def lint(_ctx),
    do: %Tau.Toolchain.LintDescriptor{
          steps: [
            %{argv: ~w(npx tsc --noEmit), report: :exit_status},
            %{argv: ~w(npx eslint .), report: :exit_status}
          ]
        }

  @impl true
  def declare_resource_namespace(_ctx) do
    [
      %Tau.Toolchain.ResourceNS{kind: :env, var: "npm_config_cache"},  # ~/.npm
      %Tau.Toolchain.ResourceNS{kind: :env, var: "XDG_CACHE_HOME"}
    ]
  end
end
```

Both adapters emit **`:junit`** — the same engine-side trusted parser serves both,
confirming the §3 parser set is keyed on *format*, not *language*. Adapter
selection is by atom (`Toolchain.for(lang)` pattern-matching on `:elixir | :node |
…`), never string dispatch (non-negotiable #2).

**Host-enforced invariant (for ALL adapters).** Adapter output is parsed and
validated by the host before use; an adapter that returns a malformed descriptor,
an absent artifact, or a crashing recipe yields a **half FAIL** (fail-closed), not
a bypass. No adapter callback can reach the merge path, relax the gate floor, or
widen the isolation boundary — those live entirely on the trusted side (M, §1
`gate_floor`, W).

---

## 5. Mechanized INV-23 / INV-24 (HR-6) — move the mechanizable out of critic-prose

HR-6: the *mechanizable* halves of the spec-discipline invariants move from
critic prose into the mechanical gate; the critic judges only the genuine
residual.

### 5.1 `Tau.Factory.Gate.SpecMembership` (INV-23, pure)

```elixir
defmodule Tau.Factory.Gate.SpecMembership do
  @doc """
  Does the diff touch any SPEC-source-map boundary without a SPEC/D-NNN
  reference in the PR body? Source-maps are loaded from docs/spec/SPEC-*.md
  Appendix B (the SPEC catalog in spec-before-code.md).
  """
  @spec check(diff :: Diff.t(), pr_body :: String.t(), source_maps :: SourceMap.t()) ::
          {:pass, []} | {:fail, [boundary :: path()]}
  def check(diff, pr_body, source_maps), do: ...
end
```

- **P-SP1.** A diff hunk whose path ∈ `boundaries(source_maps)` with **no**
  `SPEC-*` / `D-NNN` token in `pr_body` ⇒ `:fail` naming that boundary (INV-23).
- **P-SP2.** A diff touching only non-SPEC'd paths ⇒ `:pass` regardless of body.

### 5.2 Lint / compile / typecheck via the Toolchain (INV-24, engine-executed)

The mechanizable part of INV-24 (`mix compile --warnings-as-errors`, format,
credo, dialyzer — and their per-language analogues) runs as a gate half through
`Toolchain.lint/1` (§4), executed **by the engine** exactly as the mutation
descriptor is (§3): the adapter supplies the `LintDescriptor` recipe; the engine
runs it and judges `exit_status`. A non-zero exit ⇒ half FAIL. This is now
mechanical, not critic-prose.

**The residual the critic still owns** is the genuinely-judgement part of INV-24
(e.g. "is this `GenServer` wrapping stateless logic?", "is this `:global` use a
violation?") and all of INV-8 (§7) — the honestly-unclosed seam. The critic
judges *only* that residual; everything mechanizable has been removed from its
plate (HR-6), which is what makes the critic's judgement focused and auditable.

---

## 6. Judgement oracles — critic & reviewer (LLM-driven, they BACK the gates)

The two judgement halves are LLM-driven workers (full topology in
`worker-fleet.md`: each is a supervised W process spawned with complete
isolation, INV-10). Within the gate they are halves of the `async_stream` fan-out
(§1) that return **structured verdicts**, not free text:

```elixir
defmodule Tau.Factory.Gate.OracleVerdict do
  @type t :: %__MODULE__{
          oracle: :critic | :reviewer,
          status: :pass | :fail,
          findings: [Finding.t()],          # each: severity, path, AC/D-NNN touched, rationale
          masking_items: [Finding.t()]       # the §2.2 surfaced items the critic MUST rule on
        }
end
```

**They back the mechanical gates; they never replace them** (`prior-art.md` §3,
the load-bearing finding: an LLM judge alone is insufficient; ImpossibleBench
monitors miss sophisticated multi-file cheats). Concretely:

- The **critic** is the mandatory adjudicator of every Masking finding (§2.2,
  P-MK3) and the sole ruler of an implementer **challenge** (`synthesis.md`; an
  independent read-only oracle, never the coordinator's own judgement).
- The **incomplete-fix test** (INV-9): a critic/reviewer finding that **falsifies
  a named AC/D-NNN** forces reopen-and-refine — it may not be deflected to a
  follow-up regardless of severity. This is enforced as a verdict rule, not left
  to taste.
- Both are part of the **gate floor** (§1 `@gate_floor`): a PASS requires both
  oracles AND all three mechanical gates. The floor is non-shrinkable by Policy
  (HR-8); an operator cannot policy away the critic.

The oracles **add** judgement on top of the mechanical floor; they cannot
subtract from it. That asymmetry is the whole anti-gaming posture.

---

## 7. The residual (INV-8) — stated honestly, not papered over

What mutation (INV-7) + oracle-separation (INV-5) + path-based masking (INV-6)
**do not** mechanically close (`synthesis.md` Residual; NFR-GAME-RESISTANCE
explicitly refuses a number here; research GAP-7):

- **Under-asserting tests.** A gating test that runs the real path but asserts
  too little (e.g. checks `exit 0` but not the output) will *fail on the reverted
  tree* (so it passes the mutation gate) yet does not actually pin the behaviour.
  Mutation cannot catch this — the test *does* depend on production, just weakly.
- **Wrong-path tests.** A test that exercises a hand-built struct rather than the
  real user entry point (`Tau.CLI.main([...])` with realistic argv) can also pass
  the mutation gate while never proving the user-facing behaviour.

**What HR-3 buys here, and what it does not.** HR-3 lets the **engine** assert the
declared user-entry symbol *appears* in the gating test (a mechanizable narrowing
of INV-8), and the mutation cross-check (§3 step 7) binds the failing id to the
real run. But "appears in the test" is not "is the exercised path"; deciding
whether the test *drives* the real entry point versus merely mentioning it remains
**critic judgement** (§6). HR-3 **narrows** the wrong-path/under-asserting residual
— it does not eliminate it. This is the one honestly-partial cell (`◐ INV-8` in
the enforcement matrix, `system-architecture.md` §3) and it is stated, not
claimed closed.

---

## 8. Telemetry (NFR-OBS-COVERAGE = 100%)

Every gate half and the run as a whole emit paired `[:tau, …]` spans
(`*.start` / `*.stop` / `*.exception`; OTP non-negotiable #5):

| Event | Measurements | Metadata |
|---|---|---|
| `[:tau, :factory, :gate, :run, :start\|:stop\|:exception]` | `duration` | `unit`, `hash`, `verdict`, `floor` |
| `[:tau, :factory, :gate, :half, :start\|:stop\|:exception]` | `duration` | `half` (`:ac_linkage\|:masking\|:mutation\|:spec_membership\|:lint\|:critic\|:reviewer`), `status` |
| `[:tau, :factory, :engine, :test_run, :start\|:stop\|:exception]` | `duration`, `exit_status` | `lang`, `report_format`, `workspace`, `tree` (`:reverted\|:real`) |
| `[:tau, :factory, :gate, :masking, :flagged]` | `count` | `unit`, `findings` |
| `[:tau, :factory, :gate, :mutation, :judged]` | `killed_count` | `unit`, `na?` |
| `[:tau, :factory, :gate, :challenge, :ruled]` | — | `unit`, `test`, `ruling` (`:upheld\|:rejected`) |

The `:engine, :test_run` span specifically records `tree: :reverted | :real` so
the mutation cross-check (§3) is observable end-to-end, satisfying NFR-AUDIT
(merge traceable back through gate verdicts → gating-test paths → AC/D-NNN).

---

## Cross-references

- Process placement, the `Task.Supervisor GateTasks` child, gate-as-transient:
  `supervision-tree.md` (Step 0–1, Step 3, Step 5).
- Abstract G + Toolchain contracts, the enforcement matrix, FC-5:
  `../03-system-architecture/system-architecture.md` (§1, §3, §4).
- HR-2 (append-only verdicts), HR-3 (engine owns execution), HR-6 (mechanize
  INV-23/24), HR-8 (gate-floor non-shrinkable): `../05-verification/synthesis.md`.
- INV-1/5/6/7/8/9/23/24, NFR-GAME-RESISTANCE: `../02-requirements/invariants.md`,
  `../02-requirements/nfrs.md`.
- W isolation + the host-allocated workspace the engine runs tests in:
  `worker-fleet.md`. L append-only verdict log: `durable-spine.md`. Policy clamp
  of the gate floor: `governance.md`.
