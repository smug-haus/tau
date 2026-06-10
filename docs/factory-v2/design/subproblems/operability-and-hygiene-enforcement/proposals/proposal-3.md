---
template_version: 1
template_name: proposal
proposal_id: 3
parent_problem: ../problem.md
---

# Proposal 3: LiveDashboard-style read model + janitor cron + pre-spawn hook (adapt-from-prior-art)

## Approach

Build the operability and hygiene surface by composing four well-understood
prior-art patterns end-to-end, each carrying its proven semantics across:

1. **A Phoenix LiveDashboard-style read model** mounted into the already-
   planned `:tau_web` poncho (SPEC-WEB-DASHBOARD) at
   `/factory/dashboard`, populated by a single `Tau.Factory.ReadModel`
   GenServer that subscribes to `Tau.PubSub` for gate-verdict events and
   `git for-each-ref` / `gh api` polls for repo state. The read model is
   live (PubSub-pushed) for verdict updates and snapshot-polled (60 s)
   for git/GH state.
2. **A janitor scheduled workflow** (GitHub Actions cron, every 15 min on
   `main`) that runs the worktree-cleanup sequence from
   `.claude/rules/worktree-discipline.md`, removes finished agent
   worktrees, prunes orphan branches with no open PR and no commits in
   N days, syncs `main` to `origin/main`, and emits one
   `[:tau, :factory, :janitor, :sweep]` telemetry event per pass with
   counts of `{removed, kept, blocked}`.
3. **A `SessionStart` + `PreToolUse(Task)` Claude Code hook**
   (`.claude/hooks/parent-on-main.py`) that runs the pre-spawn checklist
   (`git fetch origin && rev-parse main == origin/main && branch ==
   main && status --porcelain empty`) and **exits non-zero** on any
   violation, blocking the agent spawn with a diagnostic that names the
   failed invariant and the recovery command. No agent self-discipline
   path remains.
4. **An "incident-room" alarm channel** (per-PagerDuty pattern, not the
   service) that the janitor and the read model both write to: when
   cleanup is blocked, a stale orphan exceeds a threshold, or the read
   model loses its data source, the alarm path opens a GitHub issue
   labelled `area:factory-hygiene` with a deterministic title (so
   reruns dedupe) and emits a `[:tau, :factory, :hygiene, :alarm]`
   telemetry event. The dashboard surfaces open alarms as a top-row
   banner.

Verdicts are written by the gates themselves into a single SQLite file
(`.factory/verdicts.sqlite`, Datasette-compatible schema) committed
nowhere and recreated from PubSub replay + the GitHub Checks API on cold
start; the read model is the consumer.

## Rationale

The leaf's complecting hypothesis names three knots: (a) factory state
is scattered across `.claude/logs/`, PR bodies, GHA runs, and human
memory; (b) worktree hygiene is woven into agent discipline; (c) the
`parent-on-main` check is woven into coordinator attention. Each of the
four borrowed patterns is *already* the canonical decomplecting move
for one of these knots in its origin domain:

- LiveDashboard separates "what the BEAM is doing" from "where you look"
  by being the single, push-driven view of process/ETS/telemetry state.
- Janitor crons (Jenkins workspace-cleanup, GHA `actions/stale`) separate
  hygiene enforcement from the actor producing the mess, by running on
  a fixed cadence in a context that owns nothing.
- Pre-receive / pre-spawn hooks (git server-side hooks, k8s admission
  controllers) move invariant enforcement *out of* the actor's control
  flow into an inspection layer the actor cannot bypass.
- Incident-room alarm channels (PagerDuty, Argo CD's degraded-app
  banner) separate "something is wrong" from "someone happens to be
  looking at logs" by making the wrong-state itself a first-class,
  routed signal.

Adapting all four together rather than picking one yields a system
whose observability, hygiene enforcement, invariant gating, and
alarm-on-degradation are independently load-bearing. Removing any
single one degrades only that capability; none of them recreates the
others' coupling.

## Sketch

### Read-model module

```elixir
# web/lib/tau_web/factory_dashboard_live.ex
defmodule TauWeb.FactoryDashboardLive do
  use TauWeb, :live_view
  alias Tau.Factory.ReadModel

  @poll_interval_ms 60_000

  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(Tau.PubSub, "factory:verdicts")
      Phoenix.PubSub.subscribe(Tau.PubSub, "factory:hygiene")
      :timer.send_interval(@poll_interval_ms, :poll_git)
    end

    {:ok, assign(socket, ReadModel.snapshot())}
  end

  def handle_info({:verdict, %ReadModel.Verdict{} = v}, socket),
    do: {:noreply, ReadModel.apply_verdict(socket, v)}

  def handle_info(:poll_git, socket),
    do: {:noreply, assign(socket, ReadModel.poll_git_state())}

  def handle_info({:alarm, %ReadModel.Alarm{} = a}, socket),
    do: {:noreply, ReadModel.push_alarm(socket, a)}
end

# lib/tau/factory/read_model.ex
defmodule Tau.Factory.ReadModel do
  use GenServer

  defstruct gates: %{},            # %{gate_name => :wired | :unwired}
            verdicts: [],          # last 200 %Verdict{}
            orphan_worktrees: [],  # from `git worktree list --porcelain`
            stale_branches: [],    # from gh api repos/:o/:r/branches
            parent_on_main: nil,   # boolean | :unknown
            last_coherence_run: nil,
            open_alarms: [],
            open_findings: %{},    # %{surface => count}
            inflight_prs: []       # by milestone

  defmodule Verdict do
    defstruct [:pr, :gate, :status, :reason, :run_url, :ts]
    # status: :pass | :fail | :checked_no_findings | :infrastructure_fail
    # NOTE: :skipped is REJECTED at construction; see silent-skip
    # impossibility below.
  end

  defmodule Alarm do
    defstruct [:kind, :detail, :opened_at, :issue_url]
  end

  def snapshot, do: GenServer.call(__MODULE__, :snapshot)
  def record_verdict(%Verdict{} = v), do: GenServer.cast(__MODULE__, {:verdict, v})
  # ... handle_call/3, handle_cast/2, poll_git_state/0
end
```

### Janitor workflow

```yaml
# .github/workflows/factory-janitor.yml
name: factory-janitor
on:
  schedule: [{cron: '*/15 * * * *'}]
  workflow_dispatch:

jobs:
  sweep:
    runs-on: ubuntu-latest
    timeout-minutes: 5
    steps:
      - uses: actions/checkout@v4
        with: {fetch-depth: 0}
      - name: Sweep finished worktrees and stale branches
        run: ./scripts/factory-janitor.sh
      - name: Report
        # Always runs; never short-circuits. If sweep failed, this opens
        # an `area:factory-hygiene` issue (or updates the existing one)
        # via gh issue create/comment with a deterministic title.
        if: always()
        run: ./scripts/factory-janitor-report.sh "${{ job.status }}"
```

```bash
# scripts/factory-janitor.sh — pseudocode
set -euo pipefail

git fetch origin --prune
git checkout main && git pull --ff-only origin main

REMOVED=0; KEPT=0; BLOCKED=0

for path in $(git worktree list --porcelain | awk '/^worktree/ {print $2}'); do
  [ "$path" = "$PWD" ] && continue
  if worktree_finished "$path"; then
    capture_before_destroy "$path"
    git worktree remove -f -f "$path" && REMOVED=$((REMOVED+1)) \
      || BLOCKED=$((BLOCKED+1))
  else
    KEPT=$((KEPT+1))
  fi
done

# Stale branches: remote branches with no open PR + no commit in 7 days.
gh api "repos/$REPO/branches?per_page=100" --paginate \
  | jq -r '.[].name' \
  | while read -r br; do
      should_prune "$br" && git push origin --delete "$br"
    done

emit_telemetry_event removed=$REMOVED kept=$KEPT blocked=$BLOCKED
```

### Pre-spawn hook (Claude Code)

```python
# .claude/hooks/parent-on-main.py
#!/usr/bin/env python3
"""SessionStart + PreToolUse(Task) hook: enforce parent-on-main."""
import json, subprocess, sys

def sh(cmd):
    return subprocess.run(cmd, capture_output=True, text=True, shell=True)

def main():
    payload = json.load(sys.stdin)
    if payload.get("tool_name") and payload["tool_name"] != "Task":
        sys.exit(0)  # only gate Task spawns (and SessionStart, which has
                     # no tool_name)

    sh("git fetch origin --quiet")
    main_sha   = sh("git rev-parse main").stdout.strip()
    origin_sha = sh("git rev-parse origin/main").stdout.strip()
    branch     = sh("git branch --show-current").stdout.strip()
    dirty      = sh("git status --porcelain").stdout.strip()

    failures = []
    if branch != "main":
        failures.append(("branch-not-main",
                         "git checkout main"))
    if main_sha != origin_sha:
        failures.append(("main-not-at-origin",
                         "git pull --ff-only origin main"))
    if dirty:
        failures.append(("dirty-worktree",
                         "stash or commit before spawning"))

    if failures:
        diag = "\n".join(f"  - {name}: {fix}" for name, fix in failures)
        print(f"REFUSING SPAWN: parent-on-main invariant violated:\n{diag}",
              file=sys.stderr)
        sys.exit(2)  # PreToolUse exit=2 blocks the tool call

if __name__ == "__main__":
    main()
```

```jsonc
// .claude/settings.json (delta)
{
  "hooks": {
    "SessionStart": [{"hooks": [{"type": "command",
      "command": "${CLAUDE_PROJECT_DIR}/.claude/hooks/parent-on-main.py"}]}],
    "PreToolUse": [{"matcher": "Task", "hooks": [{"type": "command",
      "command": "${CLAUDE_PROJECT_DIR}/.claude/hooks/parent-on-main.py"}]}]
  }
}
```

### Verdict-emission contract (silent-skip impossibility)

Every gate, on every run, MUST call:

```elixir
Tau.Factory.ReadModel.record_verdict(%Verdict{
  pr: pr_number,
  gate: :ac_linkage | :masking | :mutation | :contract_drift | :nn7 | ...,
  status: :pass | :fail | :checked_no_findings | :infrastructure_fail,
  reason: short_string,
  run_url: github_actions_run_url,
  ts: DateTime.utc_now()
})
```

The dashboard renders any PR with a gate that has emitted **no verdict
for the current `HEAD` SHA** as RED with the label "missing verdict"
— a missing verdict is observably worse than a fail. The
`:skipped` status is not a valid value of the `status` field; the
`Verdict.new/1` constructor pattern-matches and raises if passed
`:skipped`. A gate that "has nothing to check" emits
`:checked_no_findings`; a gate whose runner crashed emits
`:infrastructure_fail` and the PR is treated as failing.

### Alarm channel

```elixir
# lib/tau/factory/alarms.ex
defmodule Tau.Factory.Alarms do
  @doc """
  Raise an alarm; idempotent on `kind + detail` digest.
  Opens an issue labeled area:factory-hygiene with a deterministic title.
  """
  def raise(kind, detail) do
    digest = :crypto.hash(:sha256, "#{kind}:#{detail}") |> Base.encode16()
    title  = "[hygiene/#{kind}] #{summarise(detail)} (#{String.slice(digest, 0..7)})"
    case gh_issue_find(title) do
      {:ok, _existing} -> :acked
      :none -> gh_issue_create(title, detail, ["area:factory-hygiene"])
    end
    Phoenix.PubSub.broadcast(Tau.PubSub, "factory:hygiene",
      {:alarm, %ReadModel.Alarm{kind: kind, detail: detail,
                                opened_at: DateTime.utc_now()}})
    :telemetry.execute([:tau, :factory, :hygiene, :alarm],
                       %{count: 1}, %{kind: kind})
  end
end
```

## Tradeoffs

### Strengths

- **Each capability has prior-art warranty.** LiveDashboard, GHA cron
  janitors, server-side pre-receive hooks, and PagerDuty-style
  deduped alarm channels each have years of production use; the design
  inherits their failure modes (well-understood) instead of inventing
  new ones.
- **Silent-skip is impossible by data model**, not by convention: the
  `Verdict` struct does not admit a `:skipped` status; missing verdicts
  render RED; the janitor's `if: always()` reporter ensures even a
  crashed sweep produces a visible alarm.
- **`parent-on-main` enforcement is shifted left** to the spawn layer
  (Claude Code hook exit=2 blocks the Task tool call), removing the
  invariant from agent context entirely; an agent cannot fail to
  enforce a check it never has the option to run.
- **Reuses `:tau_web` and `Tau.PubSub`** per root §Acceptance D,
  satisfying SPEC-WEB-DASHBOARD D-184 (no second `Phoenix.PubSub`); no
  new HTTP service, no new datastore type the project doesn't already
  run.
- **The dashboard's own failure is itself surfaced**: per the
  acceptance criterion clause (b), a panel that cannot fetch shows an
  error state, not a blank panel — implemented because each panel
  binds to a `case ReadModel.fetch(...)` return that includes
  `{:error, reason}` and renders the error inline.
- **Decouples janitor and dashboard from the actor that produced the
  mess.** The janitor runs in CI, owns no agent worktree, and so
  cannot collide with one mid-write; the dashboard reads, never
  writes; both fail closed and loud.

### Weaknesses

- **The `:tau_web` poncho dependency is a real coupling.** If
  SPEC-WEB-DASHBOARD's foundation (issue #374) is not landed before
  this leaf's components, the LiveView panel cannot mount and the
  dashboard degrades to a Datasette-over-SQLite fallback; the design
  must explicitly state and accept that fallback. We carry an
  `if-:tau_web-absent` plan but it is genuinely lower-fidelity.
- **GHA `schedule:` triggers are best-effort.** GitHub explicitly
  warns the `*/15` cadence can stretch under load; in a quiet
  repository the janitor may not run for hours. We mitigate with
  `workflow_dispatch` and a `PostToolUse` hook that triggers the
  janitor on merge, but the 15-minute SLA is aspirational.
- **The pre-spawn hook is bypassable by the user** (Claude Code
  honours the hook contract; a user invoking Claude Code with hooks
  disabled would bypass). The hook gates *agent* spawns; it does not
  gate *human* git operations. Pair with a server-side branch
  protection rule on `main` for the human-bypass case.
- **Verdict aggregation in SQLite is a new file in the repo's local
  state.** It is regenerated from PubSub replay + Checks API on cold
  start, but means the read model has warm-start logic to maintain.
- **The alarm channel will open GitHub issues.** Deduped, but a
  pathological cascade (e.g. every PR triggers an infrastructure-fail
  alarm) would still produce many issues; we'd need a circuit breaker
  on alarm rate (≥ N alarms/hour → throttle, log only).
- **Four moving parts is more than a single dashboard.** Each part is
  individually simple, but maintainers must understand all four (read
  model, janitor, hook, alarm channel) and their wiring. A single
  monolithic dashboard would be simpler to *explain* (worse to *trust*).

### Costs

- **New files:** `web/lib/tau_web/factory_dashboard_live.ex` (~150
  LoC), `lib/tau/factory/read_model.ex` (~350 LoC),
  `lib/tau/factory/alarms.ex` (~80 LoC),
  `.github/workflows/factory-janitor.yml` (~40 LoC),
  `scripts/factory-janitor.sh` (~120 LoC),
  `scripts/factory-janitor-report.sh` (~40 LoC),
  `.claude/hooks/parent-on-main.py` (~60 LoC).
- **Schema:** ~6-table SQLite schema in `.factory/verdicts.sqlite`
  (verdicts, gates, alarms, worktree_snapshots, branch_snapshots,
  coherence_runs); migration mechanism is `Tau.Factory.ReadModel`'s
  cold-start replay, no Ecto.
- **Test surface:** unit tests for `ReadModel.apply_verdict/2` and
  `Alarms.raise/2` idempotence (~30 tests); a smoke test that
  `bin/tau` plus the LiveView route renders against a fixture
  PubSub stream; a bash test for the janitor's
  capture-before-destroy invariant under `git worktree list`
  scenarios.
- **CI minutes:** 96 janitor runs/day × ~30 s = ~50 min/day on the
  Actions free tier; well within budget.
- **Knowledge:** maintainers must know LiveView basics, GHA cron
  semantics, Claude Code hook contract, and the Verdict schema; one
  ADR (`docs/adr/NNNN-factory-read-model.md`) carries the rationale.

## Dependencies

- **SPEC-WEB-DASHBOARD foundation** (issue #374 / `web/` poncho)
  merged so `:tau_web` is mount-ready; if absent, fall back to
  Datasette over `.factory/verdicts.sqlite` exposed via `bin/tau
  dashboard` subcommand. The fallback is explicitly lower-fidelity
  (no PubSub-live updates) and is recorded as a known limitation.
- **`Tau.PubSub`** (already present per SPEC-WEB-DASHBOARD D-184).
- **Sibling leaf `pre-merge-evidence-and-skip-integrity`** —
  defines the gate-result contract this leaf's `Verdict` struct
  models; this leaf must agree with that sibling on the four allowed
  `status` values (`:pass`, `:fail`, `:checked_no_findings`,
  `:infrastructure_fail`).
- **Sibling leaf `pre-merge-code-gates`** — supplies the gate
  inventory the dashboard's "wired gates" panel renders.
- **Sibling leaf `knowledge-memory-and-audit-ingestion`** — supplies
  the "open audit-finding count by surface" panel data source.
- **GitHub repo settings** — branch protection on `main` requiring
  the janitor workflow to not be failing (covers the human-bypass
  case of the pre-spawn hook).
- **`gh` CLI available in CI** (already used by `.github/workflows/`).

## Confidence

**Medium-high.** Each constituent pattern is independently proven; the
composition's novelty is small. Confidence is not "high" because (a)
GHA `schedule:` cadence under low repo activity is an acknowledged
soft spot; (b) the `:tau_web` dependency adds a real coupling whose
fallback path (Datasette) is a downgrade; (c) the alarm-rate
circuit-breaker is sketched but not specified. Confidence would rise
to "high" with a 1-week prototype showing: LiveView mount over a
fixture PubSub stream renders 5 panels including error states; the
janitor script passes a 10-scenario shell-test matrix
(orphan, locked-finished, in-flight-protected, stale-branch-with-PR,
stale-branch-no-PR, dirty-worktree, etc.); and the hook exits 2
under each named violation in CI.

## Prior art / references

- **Phoenix LiveDashboard** —
  <https://hexdocs.pm/phoenix_live_dashboard> — the canonical
  "single view of running-system state" precedent in the BEAM
  ecosystem; mounts at `/dashboard`, PubSub-driven, error-tolerant
  panels.
- **Erlang `:observer`** — the original; LiveDashboard's lineage.
  Pattern: separate observer process, never blocks the observed.
- **Argo CD degraded-app banner** —
  <https://argo-cd.readthedocs.io/en/stable/user-guide/health/> —
  prior art for "drift between declared and observed state is itself
  a first-class signal surfaced in the UI."
- **PagerDuty deduplication keys** —
  <https://support.pagerduty.com/main/docs/event-management> — prior
  art for `kind + detail digest`-based alarm dedup so one root
  cause doesn't flood the channel.
- **`actions/stale` GitHub Action** —
  <https://github.com/actions/stale> — prior art for the
  cadence-based janitor pattern (stale-issue/PR sweep on cron).
- **Git `pre-receive` hooks and Kubernetes admission controllers** —
  prior art for "invariant enforced by an inspection layer the
  actor cannot bypass." Claude Code's `PreToolUse` hook fills the
  same niche for agent spawns.
- **Jenkins workspace cleanup plugin** —
  <https://plugins.jenkins.io/ws-cleanup/> — prior art for janitor
  patterns that decouple cleanup from the build actor.
- **Datasette** — <https://datasette.io> — the fallback dashboard
  surface if `:tau_web` is absent; SQLite-as-API with built-in error
  panels.
- **Honeycomb / Grafana Tempo dashboards** — prior art for telemetry-
  driven operational views; informs the `[:tau, :factory, ...]`
  event namespace design.
- **SPEC-WEB-DASHBOARD** (`docs/spec/SPEC-WEB-DASHBOARD.md`) — the
  in-project precedent and the host this dashboard mounts into;
  D-180..D-189 govern the mount-replay-subscribe pattern this
  proposal inherits.
- **`.claude/rules/worktree-discipline.md`** — the prose rule this
  proposal converts to mechanism; the capture-before-destroy
  sequence and pre-spawn checklist are lifted verbatim into
  `scripts/factory-janitor.sh` and `.claude/hooks/parent-on-main.py`
  respectively.

## Rejections — patterns surveyed but not adopted

- **Spinnaker pipeline-stage UI.** Strong precedent for "all
  pipeline state in one view," but its model is heavyweight
  (Kubernetes operator, JVM stack); adopting it would dwarf the
  surface it observes. Reject as scope-mismatch.
- **OpenTelemetry collector + Grafana Tempo stack.** Excellent for
  long-term tracing, but for the "show me factory state right now"
  query it adds two services (collector, store) the project doesn't
  need yet. Reuse `Tau.PubSub` and `:telemetry` instead. Could
  layer in later for historical analytics.
- **`git rerere`, `git-absorb`.** Solve different problems
  (conflict-resolution memo, fixup-routing) than worktree hygiene.
  Out of scope.
- **`git-trim`.** Closer match for stale-branch pruning, but is a
  local-only tool. The janitor needs to prune *remote* branches
  authoritatively from CI; a 30-line `gh api` loop is more direct
  than wrapping `git-trim`.
- **Squadcast / PagerDuty as a service.** The dedup *pattern* is
  adopted; the SaaS itself is not — would introduce a third-party
  account dependency for a single-developer project. GitHub issues
  are the alarm channel.
- **PR-comment dashboards (Reviewable, Graphite).** Solve PR review
  UX, not factory-wide operability. Tangential.

## Silent-skip impossibility — the proof

Three distinct mechanisms make silent-skip structurally impossible,
not merely discouraged:

1. **Schema-level rejection.** `Tau.Factory.ReadModel.Verdict.new/1`
   pattern-matches `status` against the closed set
   `[:pass, :fail, :checked_no_findings, :infrastructure_fail]` and
   raises on any other value (including `:skipped`). A gate cannot
   emit a verdict whose status is "skipped"; the type system refuses.
2. **Missing-verdict-is-RED.** The dashboard cross-references the
   wired-gate inventory with verdicts-keyed-by-HEAD-SHA. Any gate
   with no verdict for the current PR's HEAD renders RED with the
   label "missing verdict." A gate that silently exits 0 without
   calling `record_verdict/1` is therefore *louder* than a gate
   that emits `:fail` — the dashboard treats it as the worst case.
3. **`if: always()` reporter.** The janitor workflow's reporter step
   uses `if: always()`. If the sweep crashes, the reporter still
   runs and opens / updates the `area:factory-hygiene` issue via
   `Tau.Factory.Alarms.raise/2`. The dashboard's "open alarms"
   banner surfaces it. There is no path by which a janitor crash
   produces silence.

Cross-check against the ten failure classes: silent-skip is
specifically failure class #5 (CI gates silent-skip, `|| true` in
ci.yml). The three mechanisms above cover both gate-side (1, 2) and
infrastructure-side (3) silence. A gate that simply omits the
`record_verdict` call falls into mechanism 2's net; a gate that
explicitly tries to record a "skip" falls into mechanism 1's net;
a gate that crashes the whole workflow falls into mechanism 3's
net. There is no fourth path.
