---
template_version: 1
template_name: proposal
proposal_id: 4
parent_problem: ../problem.md
---

# Proposal 4: Adversarial AC-binding — per-AC call-site mutation derived from a structured binding manifest

## Approach

Replace the prose-only `## Acceptance criteria` PR-body section with a
**structured, machine-resolvable AC binding manifest** committed to the PR
branch as `factory/ac-bindings.yaml`, plus a Mix-task gate
(`tau.gate.ac_binding`) that, for every `AC-N` declared, performs four
mechanical checks in sequence and FAILS THE PR if any check is missing,
empty, unresolvable, or does not produce the expected red/green delta. The
four checks are: (1) **resolve** — every claimed user-facing entry point
(`{module, function, arity}` or `{cli, argv_pattern}`) exists in HEAD; (2)
**reach** — at least one gating-test execution actually calls that entry
point (verified with `excoveralls` line+function tracking, not commit
attribution); (3) **mutate-at-call-site** — comment out *only the named
call site inside the production function the AC targets*, recompile, run
that AC's tagged tests, assert ≥1 fails; (4) **restore** — assert the
suite returns green when the call site is restored. Silent-skip is
impossible because the manifest is required (`{:error,
:no_manifest}` → fail), every AC requires non-empty entries
(`{:error, :empty_entry, "AC-N"}` → fail), and a per-AC mutation that
produces no red test (`{:error, :no_red, "AC-N"}` → fail) is a verdict,
never a skip.

## Rationale — adversarial design from v1's exact failures

The v1 audit's AC-B6 falsification probe (root §Hypothesis #6) and the
declared-semantics-fidelity findings establish four concrete failure
geometries. This proposal designs the minimum mechanism that catches
EACH, then generalises.

### Failure construction 1 — Wrong-path test (AC-B6 verbatim)

**Concrete PR-body claim** (verbatim from PR-B / #341):

```markdown
## Acceptance criteria

- **AC-B6** — typing `/perms accept_edits` + Enter sets `permissions_mode`
  via `Tau.Session.set_permissions_mode/2`.
```

**Concrete test** (verbatim from
`test/tau/tui/permission_dialog_test.exs:360-369`):

```elixir
@tag :ac_b6
test "AC-B6: `/perms accept_edits` + Enter sets permissions_mode to :accept_edits" do
  m0 = build_idle_model_with_session(:default)
  next = run_perms_command(m0, "accept_edits")
  assert next.model.permissions_mode == :accept_edits, ...
end

defp run_perms_command(model, arg) do
  # Updates model.permissions_mode locally, then casts to the session pid.
  # The cast handler in the test stub is dead code for this AC.
  ...
end
```

**v1 gate misfire.** `Mix.Gate.AcLinkage.ac_linkage/2` finds `:ac_b6` in
the test name and returns `:ok`. `Mix.Gate.Mutation.mutation_check/2`
reverts every non-test path to merge-base; because PR-B is large, *some*
test in the suite fails, so `:ok` is returned. Both gates pass while
`Tau.Session.set_permissions_mode/2` is never called by the test.

**Catching mechanism.** `factory/ac-bindings.yaml`:

```yaml
- ac: AC-B6
  user_path:
    kind: elixir_call
    module: Tau.Session
    function: set_permissions_mode
    arity: 2
    call_site_file: lib/tau/tui/app.ex
    call_site_line_anchor: |
      Tau.Session.set_permissions_mode(model.session_id, mode)
  gating_tests:
    - test/tau/tui/permission_dialog_test.exs:360-369
    - test/tau/tui/permission_dialog_test.exs:371-380
  expected_red_under_mutation:
    - test/tau/tui/permission_dialog_test.exs:360-369
```

The gate's **mutate-at-call-site** step finds the `call_site_line_anchor`
in `lib/tau/tui/app.ex`, replaces *only that line* with `:ok # MUTATED`,
recompiles, runs `mix test --only ac_b6`, and asserts the named test goes
red. With the v1 wrong-path test, the call site never fires, so the test
stays green → gate FAILS with `{:error, :no_red, "AC-B6", ...}`.

### Failure construction 2 — Hand-built struct bypasses parser

**Concrete PR-body claim**: PR introduces `--system-prompt-file` flag with
AC: "`tau run --system-prompt-file <persona>` honours the persona's
`allowed-tools:` whitelist."

**Concrete test**:

```elixir
@tag :ac_persona
test "AC-PERSONA: persona allowlist honoured" do
  # Hand-built session struct skips the CLI parser entirely.
  session = %Tau.Session{tools: ["read"], system_prompt: "..."}
  refute Tau.PermissionsEvaluator.evaluate(session, "bash") == :allow
end
```

**Catching mechanism.** Binding manifest declares
`user_path.kind: cli_argv`:

```yaml
- ac: AC-PERSONA
  user_path:
    kind: cli_argv
    entry: Tau.CLI.main
    argv_pattern: ["run", "--system-prompt-file", "*"]
    sentinel_call:
      module: Tau.CLI.PersonaLoader
      function: parse_frontmatter
      arity: 1
  gating_tests:
    - test/tau/cli/persona_test.exs
```

The gate's **reach** step (excoveralls function-trace) verifies that
running `mix test --only ac_persona` *calls*
`Tau.CLI.PersonaLoader.parse_frontmatter/1`. The hand-built-struct test
never calls it → gate FAILS with `{:error, :unreached_sentinel,
"AC-PERSONA", "Tau.CLI.PersonaLoader.parse_frontmatter/1"}`.

### Failure construction 3 — Silent-skip via empty Gating-test paths

**Concrete PR-body** (v1 cycle step 4b skipped):

```markdown
## Acceptance criteria
- **AC-9** — circuit breaker opens after 5 failures.

## Gating-test paths
(none — refactor only)
```

**v1 gate misfire.** `Mix.Gate.Mutation.mutation_check([], base_ref)`
short-circuits to `:not_applicable` because `project_creation_pr?` is
called on an empty list. `Mix.Gate.AcLinkage` is asked to check tokens
against an empty `gating_test_sources` list; the existing implementation
returns `{:error, [...]}` only if the AC section is non-empty — but
nothing forces the *existence* of the manifest.

**Catching mechanism.** `tau.gate.ac_binding` makes manifest absence a
hard fail:

```elixir
case File.read("factory/ac-bindings.yaml") do
  {:error, :enoent} ->
    # AC tokens appear in PR body?
    if has_ac_tokens?(pr_body), do: exit({:error, :no_manifest}), else: exit({:ok, :no_acs})
  {:ok, body} ->
    bindings = YAML.decode!(body)
    if Enum.empty?(bindings), do: exit({:error, :empty_manifest})
    Enum.each(bindings, &enforce_binding/1)
end
```

A PR that claims `AC-N` in its body but ships no `factory/ac-bindings.yaml`
fails with `:no_manifest`. A PR that ships the file with zero entries
fails with `:empty_manifest`. A PR that claims no ACs at all (refactor,
typo) passes with `:no_acs` — and that exemption is itself
**cross-checked** by gate 5.1's existing AC-token scan of the PR body.

### Failure construction 4 — AC text names a struct/function that doesn't exist

**Concrete PR-body claim** (root §Hypothesis #1):

```markdown
## Acceptance criteria
- **AC-CACHE** — `Tau.Provider.Anthropic.cache_regions/2` returns the
  declared region list verbatim.
```

But `lib/tau/providers/anthropic.ex` at HEAD does not export
`cache_regions/2` (the `@behaviour` callback was renamed during the PR).

**Catching mechanism.** The **resolve** step compiles HEAD and asks the
runtime: `function_exported?(Tau.Provider.Anthropic, :cache_regions, 2)`
— or for CLI ACs, parses argv against `OptionParser` and asserts the
flag is registered. False → `{:error, :unresolvable, "AC-CACHE",
"Tau.Provider.Anthropic.cache_regions/2"}` → PR fails.

This catches AC-side contract drift before the production-code AST
gates (which live in the pre-merge-code-gates sibling) even have a
chance to run.

### Failure construction 5 — Mutation reverts but suite fails for the wrong reason

**Concrete v1 misfire.** PR adds a new public function
`Tau.Foo.bar/1` and tags AC-FOO tests. The v1 mutation check reverts the
entire `lib/` tree to merge-base; `Tau.Foo` does not exist at merge-base
so *compilation breaks*. `Mix.Gate.Mutation` interprets `mix test`
exiting without a summary as `{:error, {:runner_crashed, ...}}` — but
in PR #372's regression the original `CaseClauseError` was reinterpreted
as `:not_applicable` via the `project_creation_pr?` escape hatch when
the PR happened to live in a sub-project.

**Catching mechanism.** Per-AC, *surgical* mutation rather than
global revert. Only the `call_site_line_anchor` line is mutated;
compilation must succeed (the line is replaced with a syntactically
valid no-op like `:ok`); if compilation fails the gate exits with
`{:error, :mutation_broke_compile, "AC-FOO"}` — never with
`:not_applicable`. There is no escape hatch.

### Generalisation across the failure class

Every failure above shares the same generator: the AC declaration's
link to the user-facing path is **prose, not data**. The proposal
replaces that prose with a typed manifest whose every field is
mechanically resolved against HEAD, against the test runner's
function-trace, and against a per-AC surgical mutation. The mutation
check operates at the granularity of the *specific call site the AC
names*, not the whole tree. This generalises beyond the five
constructions: any future AC that ships a wrong-path test, a vacuous
test, a stale-name claim, or no test at all is caught by the same
gate, because the gate's input is structured and its checks are
mechanical.

## Sketch

### Artifact 1 — Binding manifest schema (committed to PR branch)

`factory/ac-bindings.yaml`:

```yaml
# YAML list; one entry per AC-N or D-NNN claimed in the PR body.
- ac: AC-B6                        # required; matches PR body
  user_path:                       # required; one of:
    kind: elixir_call              #   elixir_call | cli_argv | telemetry_event
    module: Tau.Session            #   for elixir_call
    function: set_permissions_mode
    arity: 2
    call_site_file: lib/tau/tui/app.ex     # required for elixir_call
    call_site_line_anchor: |               # required; exact line text
      Tau.Session.set_permissions_mode(model.session_id, mode)
    mutation_replacement: ":ok"            # optional; defaults to ":ok"
  gating_tests:                    # required; non-empty
    - test/tau/tui/permission_dialog_test.exs
  expected_red_under_mutation:     # required; non-empty subset of gating_tests
    - test/tau/tui/permission_dialog_test.exs

# For CLI-entry ACs:
- ac: AC-PERSONA
  user_path:
    kind: cli_argv
    entry_module: Tau.CLI
    entry_function: main
    entry_arity: 1
    argv_pattern: ["run", "--system-prompt-file", "*"]
    sentinel:                      # the call the user-path MUST reach
      module: Tau.CLI.PersonaLoader
      function: parse_frontmatter
      arity: 1
  gating_tests:
    - test/tau/cli/persona_test.exs
  expected_red_under_mutation:
    - test/tau/cli/persona_test.exs
```

### Artifact 2 — `Mix.Gate.AcBinding` (replaces 5.1+5.3 for ACs)

```elixir
defmodule Mix.Gate.AcBinding do
  @moduledoc "Gate AC-1 — per-AC binding manifest enforcement. No silent-skip."

  @type binding :: %{
    ac: String.t(),
    user_path: user_path(),
    gating_tests: [String.t()],
    expected_red_under_mutation: [String.t()]
  }

  @spec enforce(String.t(), Path.t(), Path.t()) ::
    {:ok, :no_acs_in_pr} |
    {:ok, [binding]} |
    {:error, :no_manifest_but_acs_claimed, [String.t()]} |
    {:error, :empty_manifest} |
    {:error, :unresolvable, binding(), String.t()} |
    {:error, :unreached, binding(), mfa()} |
    {:error, :mutation_broke_compile, binding()} |
    {:error, :no_red_under_mutation, binding(), [String.t()]} |
    {:error, :missing_ac_in_manifest, [String.t()]}
  def enforce(pr_body, manifest_path, repo_dir) do
    claimed_acs = Mix.Gate.AcLinkage.parse_ac_tokens_in_body(pr_body)

    case {File.read(manifest_path), claimed_acs} do
      {{:error, :enoent}, []} -> {:ok, :no_acs_in_pr}
      {{:error, :enoent}, acs} -> {:error, :no_manifest_but_acs_claimed, acs}
      {{:ok, ""}, _} -> {:error, :empty_manifest}
      {{:ok, body}, claimed} ->
        bindings = YAML.decode!(body)
        with :ok <- assert_all_claimed_present(claimed, bindings),
             :ok <- enforce_each(bindings, repo_dir) do
          {:ok, bindings}
        end
    end
  end

  defp enforce_each(bindings, repo_dir) do
    Enum.reduce_while(bindings, :ok, fn b, _ ->
      with :ok <- resolve_user_path(b, repo_dir),
           :ok <- reach_check(b, repo_dir),
           :ok <- mutation_check_at_call_site(b, repo_dir) do
        {:cont, :ok}
      else
        err -> {:halt, err}
      end
    end)
  end
end
```

### Artifact 3 — CLI / CI wiring

```elixir
# lib/mix/tasks/tau.gate.ac_binding.ex
defmodule Mix.Tasks.Tau.Gate.AcBinding do
  use Mix.Task
  @shortdoc "Runs Gate AC-1 (binding manifest enforcement)."
  def run(_argv) do
    pr_body = System.fetch_env!("PR_BODY")
    case Mix.Gate.AcBinding.enforce(pr_body, "factory/ac-bindings.yaml", File.cwd!()) do
      {:ok, _} -> System.halt(0)
      {:error, reason, detail} ->
        IO.puts(:stderr, format_error(reason, detail))
        System.halt(1)
    end
  end
end
```

`.github/workflows/ci.yml` adds (no `|| true`, no `if:` guard):

```yaml
- name: Gate AC-1 — AC binding manifest
  env:
    PR_BODY: ${{ github.event.pull_request.body }}
  run: mix tau.gate.ac_binding
```

### Artifact 4 — Reach check via `excoveralls` function-trace

The reach check uses `:cover` (which `excoveralls` already configures —
see `mix.exs` line 134) to collect *function-level* hit data, not just
line coverage:

```elixir
defp reach_check(binding, repo_dir) do
  :cover.compile_beam_directory('_build/test/lib/tau/ebin')
  System.cmd("mix", ["test", "--only", ac_tag(binding)] ++ binding.gating_tests,
             cd: repo_dir)
  hits = :cover.analyse(module_of(binding), :calls, :function)
  if Enum.any?(hits, &called?(&1, binding)),
    do: :ok,
    else: {:error, :unreached, binding, mfa_of(binding)}
end
```

### Artifact 5 — Optional plugin `polya-audit`-style binding-author agent

A new agent under `.claude/plugins/polya-audit/agents/binding-author.md`
that, given an issue body, drafts `factory/ac-bindings.yaml` for the
implementer to commit. Output is a file diff, not prose. The agent is
**optional**: a human or any implementer may author the manifest
directly; the gate is the load-bearing mechanism, not the agent.

### Artifact 6 — `.claude/settings.json` enforcement hook

```json
{
  "hooks": {
    "PreToolUse": [{
      "matcher": "Bash",
      "command": "${CLAUDE_PLUGIN_ROOT}/hooks/check_ac_manifest_on_pr_create.py"
    }]
  }
}
```

The hook intercepts `gh pr create` invocations; if the PR body has
`AC-N` tokens but `factory/ac-bindings.yaml` is absent on the branch, the
hook BLOCKS the call and prints the manifest schema. Belt-and-braces
with the CI gate, but prevents the implementer from opening a PR that
will immediately fail Gate AC-1.

## Mechanism sequencing — greatest-failure-impact-first

Ordered by historical incidence × consequence in the v1 audit:

1. **Manifest existence + non-emptiness** (failure #3). Catches the
   widest class because v1 routinely opened PRs with no Gating-test
   paths declaration; the silent-skip path is the single highest-
   incidence misfire in the v1 logs.
2. **Per-AC mutation at the named call site** (failure #1, #5). The
   AC-B6 falsification probe is the audit's headline finding; this
   mechanism makes the wrong-path test *impossible* to ship green.
3. **Reach check via `:cover` function-trace** (failure #2). Catches
   hand-built-struct tests that the mutation check might pass if the
   AC happens to have multiple call sites; reach is the second line
   of defence.
4. **Resolve check** (failure #4). Cheap (microseconds); catches
   AC-side contract drift before any test runs; ordered fourth only
   because its failure rate in v1 was lower than #1-#3.
5. **Mutation-replacement compile guard** (failure #5 tail). Ensures
   the mutation itself does not produce a runner crash that escape-
   hatches to `:not_applicable`.

## Tradeoffs

### Strengths

- **Each v1 failure is constructed and explicitly caught.** No abstract
  "improve linkage"; every gate exit reason maps to a verbatim v1
  failure case.
- **Silent-skip is structurally impossible.** Missing manifest +
  claimed ACs = hard fail. Empty manifest = hard fail. Unresolvable
  entry = hard fail. Unreached entry = hard fail. No-red mutation =
  hard fail. There is no `:not_applicable` escape hatch on the AC
  path; the only "no-op" exit is `{:ok, :no_acs_in_pr}`, which is
  cross-checked by Gate 5.1's existing PR-body scan.
- **Surgical mutation > global revert.** Compile is preserved; the
  test that fails fails *for the reason the AC names*, not because the
  whole tree won't build.
- **Reuses Tau's existing `excoveralls` / `:cover` infrastructure.**
  The reach check is a thin wrapper around tooling already present in
  `mix.exs`; the bespoke surface is the manifest schema and the gate
  driver, not the coverage machinery.
- **Manifest is a single file** — easy to diff, easy to review,
  easy for the `critic` to read alongside the PR body.
- **Per-AC granularity** — a PR claiming six ACs gets six independent
  verdicts; partial credit becomes visible without compromising the
  pass/fail gate.

### Weaknesses

- **Manifest authoring overhead.** Implementers must write YAML for
  every AC. Mitigation: the optional `binding-author` agent drafts the
  manifest from the issue body; the implementer reviews and adjusts.
  Unmitigated risk: low-quality issue bodies → manual manifest
  authoring.
- **`call_site_line_anchor` is brittle to refactors.** If the
  implementer renames the variable used at the call site mid-PR,
  the anchor breaks. Mitigation: the gate's mutation step reports
  `{:error, :anchor_not_found, "AC-N", anchor}` rather than silent
  pass; the implementer updates the anchor. Anchor-not-found is a
  hard fail, not a skip.
- **Multi-call-site ACs need every site mutated.** If `AC-N` is
  satisfied by *one of three* call sites firing, the per-AC mutation
  must iterate. Schema extension: `call_sites:` list. Adds one loop
  layer to the gate but no conceptual change.
- **Reach check requires `:cover` to be reliable across umbrella
  apps.** Tau is moving toward a poncho structure (`web/`); the reach
  check must support per-app `_build/test/lib/.../ebin` directories.
  Engineering work, not a design flaw.
- **YAML schema drift.** A schema change must be coordinated with
  every committed manifest. Mitigation: `template_version` in
  the manifest, gate rejects unknown versions explicitly.

### Costs

- **New file in every PR with ACs.** Typical PRs claim 1-6 ACs →
  10-100 lines of YAML. Negligible diff size.
- **CI time.** Per-AC mutation = one extra `mix compile` + tagged
  `mix test` run per AC. For Tau's current suite (~30s for tagged
  runs), 6 ACs ≈ 3 minutes additional CI per PR. Acceptable.
- **Gate-author time to ship initial implementation.** Estimated
  3-5 days for `Mix.Gate.AcBinding` (~600 LOC), YAML schema, CI
  wiring, hook script, and tests. Bounded.
- **Migration cost for in-flight PRs.** Open PRs without manifests
  must add them or be rebased. Estimated <1 day given current
  in-flight count.
- **Knowledge cost.** Implementers learn the YAML schema. Documented
  in a single page; no DSL or macros.

## Dependencies

- **`excoveralls` / `:cover` function-trace** — present in `mix.exs`
  line 134; no new dep.
- **YAML parser** — `yaml_elixir` (~3KB pure Elixir) or
  `:yamerl`. New dep, well-established.
- **Gate-execution substrate from sibling
  `pre-merge-evidence-and-skip-integrity`** — provides the
  silent-skip-impossible CI harness this gate runs inside. Without
  the sibling, the gate could still be `|| true`-ed; with it, it
  cannot.
- **Audit-ingestion sibling
  (`knowledge-memory-and-audit-ingestion`)** — for future
  per-surface invariants (e.g. "any AC touching `lib/tau/session/`
  must declare an FSM state in its `user_path`"); not required
  for v1 of this gate.
- **PR-body parser already exists** in
  `Mix.Gate.AcLinkage.parse_ac_tokens` — reused, not duplicated.

## Confidence

**High** on the design; **medium** on the
`call_site_line_anchor` durability under refactor (anchored exact-line
matching is simple but brittle, and a future iteration may need AST
patching via `Sourceror`).

What would raise confidence: a one-week prototype implementing Gate
AC-1 for the existing AC-B6 case in PR-B, demonstrating that the
prototype turns AC-B6 RED with the v1 wrong-path test and GREEN with
proposal-3's fixed test (which replaces the local-update helper with
the FSM-call helper).

## Prior art / references

- `muzak` (Hex package) — Elixir mutation testing; performs AST-level
  mutations on production code. This proposal differs by mutating
  *exactly one named call site per AC* rather than exploring a
  mutation space; the AC's named call site IS the chosen mutation.
- `excoveralls` / Erlang `:cover` — coverage and function-call
  tracking; this proposal uses `:cover`'s `:calls` analysis mode to
  drive the reach check.
- Property-based testing (`StreamData`, used in Tau already) — the
  reach check is in the same spirit as a generator-driven oracle:
  the user-path call site is the oracle, the test invocation is the
  generator.
- `polya-audit` plugin (this repo) — the `binding-author` agent
  follows the same proposer/selector/validator structure already
  used by code-audit-proposer.
- Audit finding
  `docs/problems/subproblems/test-fidelity/proposals/proposal-3.md`
  — verbatim source of the AC-B6 failure construction; this proposal
  is the mechanism that would have caught it.
- v1 `.claude/rules/factory-loop.md` §"The three mechanical gates" —
  the design this proposal extends and corrects.

---

## Notes for the writer (delete before saving)

This proposal is intentionally adversarial: every design choice is
justified by a verbatim v1 failure it makes impossible. The selector
should compare it against proposals that take orthogonal axes (e.g. a
proposal that uses `muzak` directly without per-AC binding, or one
that uses a contract-by-example DSL, or one that re-architects the AC
concept itself to be code-level rather than PR-body-level).
