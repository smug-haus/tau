---
template_version: 1
template_name: proposal
proposal_id: 2
parent_problem: ../problem.md
---

# Proposal 2: Adopt Phoenix LiveDashboard + GitHub Actions + git-hooks; thin custom pages over a SQLite read-model populated by existing telemetry

## Approach

Reuse three already-mature components — **Phoenix LiveDashboard** (mounted
inside the existing `:tau_web` poncho per SPEC-WEB-DASHBOARD), **GitHub
Actions scheduled workflows + branch-protection rules**, and **`git
worktree` + server-side `pre-receive` / `update` hooks** — and add only the
glue Tau actually owns: (a) a tiny `Tau.Factory.ReadModel` GenServer that
projects existing `[:tau, :factory, ...]` `:telemetry` events and `gh api`
poll output into a single SQLite database (`priv/factory_state.db`),
(b) a `TauWeb.FactoryLive` LiveView that subscribes via `Tau.PubSub`
(D-184 — no second PubSub) and renders the dashboard panels required by
the leaf's AC (a) using LiveDashboard's `Phoenix.LiveDashboard.PageBuilder`
behaviour, (c) two `PreToolUse` hooks (`enforce-parent-on-main.py`,
`enforce-worktree-cleanup.py`) registered in `.claude/settings.json` that
share their *exact same script* with a scheduled GitHub Actions workflow
(`.github/workflows/hygiene-sweep.yml`) so the local and remote
enforcement points cannot drift, and (d) a `branch-protection.json` config
applied by `gh api` that requires the `hygiene-sweep` workflow status to
be green on `main` — closing the loop without bespoke daemons.

## Rationale

The leaf's complecting hypothesis is that "what the factory is doing"
is scattered across `.claude/logs/`, PR bodies, Actions, agent contexts,
and human memory; and that hygiene rules are complected with agent
discipline. The cure is a single read model plus mechanical enforcement
— *not* a bespoke dashboard, scheduler, or branch-policy daemon. Tau
already chose Phoenix LiveDashboard for `/dev/dashboard` (`web/lib/
tau_web/router.ex:50`), Phoenix LiveView for AC-claimed surfaces
(SPEC-WEB-DASHBOARD D-180..D-189), `[:tau, ...]` `:telemetry` namespace,
`Phoenix.PubSub` (D-184), `:exqlite`/SQLite (SPEC-MEMORY-STORE), and
GitHub Actions for CI; every one of those is a load-bearing component
the proposal **reuses without modification**. The only new code is the
projector (a textbook `Phoenix.Tracker`-shape GenServer) and the
LiveDashboard page module — both of which are stateless functions over
existing event streams, satisfying OTP non-negotiable #8 (pure
functions are the default). Hygiene enforcement collapses to a script
shared between a local PreToolUse hook and a GitHub Actions cron — the
same script, run in two places, so divergence is impossible. Branch-
protection rules make the workflow's verdict load-bearing without any
bespoke "merge daemon." This satisfies root §Acceptance D
(ecosystem reuse over reinvention) at the highest available density.

## Sketch

### Component map (reused vs new)

| Surface | Reused (no code) | Glue (Tau-owned) |
|---|---|---|
| Dashboard chrome, charts, tabs, auth-aware mount | `Phoenix.LiveDashboard` + `Phoenix.LiveDashboard.PageBuilder` | `TauWeb.FactoryLive.Page` (≤ 200 LOC) |
| Real-time push | `Phoenix.PubSub` (D-184), `Phoenix.LiveView` | subscribe in `mount/3`; broadcast from `ReadModel` |
| Telemetry stream | `:telemetry` (existing `[:tau, :factory, ...]` events) | one `:telemetry.attach_many/4` call in `ReadModel.init/1` |
| Persistent read model | `:exqlite` (already a dep — SPEC-MEMORY-STORE) | `priv/factory_state.db` with 6 tables (see schema below) |
| Gate verdicts | written by gates already (PR-body trailer, CI artifacts) | `ReadModel` parses the trailer via `gh api repos/.../pulls/:n` |
| Orphan worktree / stale-branch counts | `git worktree list --porcelain`, `git for-each-ref refs/heads/ --format='%(refname:short) %(committerdate:unix)'`, `gh pr list --state open --json headRefName` | one `Tau.Factory.Hygiene.scan/0` pure function |
| Scheduled cleanup + parent-on-main sync | GitHub Actions cron + `gh api` | `.github/workflows/hygiene-sweep.yml` (shells out to the same script as the local hook) |
| Local pre-spawn enforcement | Claude Code `PreToolUse` hook protocol | `.claude/hooks/enforce-parent-on-main.py`, `.claude/hooks/enforce-worktree-cleanup.py` |
| Branch-protection / load-bearing verdict | GitHub branch-protection rules API | `.github/branch-protection.json` applied by `gh api` |
| Alarm / issue-on-failure | GitHub Issues API + Actions `peter-evans/create-issue-from-file` action | `.github/workflows/hygiene-sweep.yml` step `on: failure` |

### SQLite read-model schema (`priv/factory_state.db`)

```sql
CREATE TABLE gate_run (
  pr_number       INTEGER NOT NULL,
  gate_id         TEXT    NOT NULL,           -- "5.1", "5.2", "5.3", "critic", "reviewer"
  verdict         TEXT    NOT NULL CHECK (verdict IN ('pass','fail','checked_no_findings','infra_fail')),
  rationale       TEXT    NOT NULL,           -- never NULL — silent-skip impossible
  diff_sha        TEXT    NOT NULL,           -- the diff the verdict covers
  ran_at          INTEGER NOT NULL,           -- unix seconds
  evidence_url    TEXT    NOT NULL,           -- GH Actions run URL (never local mix)
  PRIMARY KEY (pr_number, gate_id, ran_at)
);

CREATE TABLE pr_state (
  pr_number       INTEGER PRIMARY KEY,
  milestone       TEXT,
  status          TEXT NOT NULL,              -- 'draft'|'open'|'merged'|'closed'
  head_sha        TEXT NOT NULL,
  declared_acs    TEXT NOT NULL,              -- JSON array of AC-N / D-NNN
  closes_issues   TEXT NOT NULL               -- JSON array of int
);

CREATE TABLE worktree_state (
  path            TEXT PRIMARY KEY,
  branch          TEXT NOT NULL,
  age_seconds     INTEGER NOT NULL,
  status          TEXT NOT NULL,              -- 'active'|'orphan'|'leaked'
  observed_at     INTEGER NOT NULL
);

CREATE TABLE stale_branch (
  refname         TEXT PRIMARY KEY,
  age_seconds     INTEGER NOT NULL,
  has_open_pr     INTEGER NOT NULL CHECK (has_open_pr IN (0,1)),
  observed_at     INTEGER NOT NULL
);

CREATE TABLE main_coherence_run (
  ran_at          INTEGER PRIMARY KEY,
  verdict         TEXT NOT NULL CHECK (verdict IN ('pass','fail','checked_no_findings')),
  rationale       TEXT NOT NULL,
  evidence_url    TEXT NOT NULL
);

CREATE TABLE audit_finding (
  finding_id      TEXT PRIMARY KEY,           -- e.g. "audit-2026-04-rescue-7"
  surface_glob    TEXT NOT NULL,              -- file glob the finding applies to
  status          TEXT NOT NULL,              -- 'open'|'remediated'|'waived'
  waiver_expires  INTEGER,                    -- unix ts; NULL if no waiver
  opened_at       INTEGER NOT NULL
);
```

### `Tau.Factory.ReadModel` (new — ≤ 250 LOC)

```elixir
defmodule Tau.Factory.ReadModel do
  @moduledoc """
  Projects `[:tau, :factory, ...]` telemetry, GitHub API polls, and
  `git`/`gh` scan output into `priv/factory_state.db`. Pure projector:
  every handler is a function from event -> SQL insert. Owns the SQLite
  connection process (Exqlite).

  This is the *only* writer to `factory_state.db`. Readers (LiveView,
  scheduled workflows, ad-hoc queries via `sqlite3` or Datasette) read
  the same database.
  """
  use GenServer

  @events [
    [:tau, :factory, :gate, :stop],
    [:tau, :factory, :gate, :exception],
    [:tau, :factory, :pr, :opened],
    [:tau, :factory, :pr, :merged],
    [:tau, :factory, :hygiene, :scan, :stop]
  ]

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(opts) do
    db = Keyword.get(opts, :db_path, Application.app_dir(:tau, "priv/factory_state.db"))
    {:ok, conn} = Exqlite.Sqlite3.open(db)
    :ok = Tau.Factory.ReadModel.Schema.migrate!(conn)
    :ok = :telemetry.attach_many("tau-factory-readmodel", @events, &__MODULE__.handle/4, conn)
    schedule_poll()
    {:ok, %{conn: conn}}
  end

  def handle(event, measurements, metadata, conn) do
    Tau.Factory.ReadModel.Project.apply(conn, event, measurements, metadata)
    Phoenix.PubSub.broadcast(Tau.PubSub, "factory:state", {:projected, event, metadata})
  end

  @impl true
  def handle_info(:poll, %{conn: conn} = s) do
    Tau.Factory.Hygiene.scan() |> Enum.each(&Tau.Factory.ReadModel.Project.apply(conn, :hygiene, &1, %{}))
    schedule_poll()
    {:noreply, s}
  end

  defp schedule_poll, do: Process.send_after(self(), :poll, :timer.seconds(60))
end
```

### `TauWeb.FactoryLive.Page` (new — uses LiveDashboard PageBuilder)

```elixir
defmodule TauWeb.FactoryLive.Page do
  @moduledoc """
  Mounts as a LiveDashboard page at `/dev/dashboard/factory`. Reads from
  `priv/factory_state.db` (read-only) and re-renders on every
  `{:projected, _, _}` broadcast on `Tau.PubSub` topic `"factory:state"`.
  """
  use Phoenix.LiveDashboard.PageBuilder

  @impl true
  def menu_link(_, _), do: {:ok, "Factory"}

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Phoenix.PubSub.subscribe(Tau.PubSub, "factory:state")
    {:ok, assign(socket, snapshot: Tau.Factory.ReadModel.Query.snapshot())}
  end

  @impl true
  def handle_info({:projected, _, _}, socket) do
    {:noreply, assign(socket, snapshot: Tau.Factory.ReadModel.Query.snapshot())}
  end

  @impl true
  def render_page(assigns) do
    nav_bar(items: [
      gates: %{name: "Gates",     render: &gates_panel/1,    method: :patch},
      prs:   %{name: "Open PRs",  render: &prs_panel/1,      method: :patch},
      hyg:   %{name: "Hygiene",   render: &hygiene_panel/1,  method: :patch},
      coh:   %{name: "main",      render: &coherence_panel/1,method: :patch},
      audit: %{name: "Audits",    render: &audits_panel/1,   method: :patch}
    ])
  end

  # Each *_panel/1 is a card/table renderer over snapshot fields.
  # A panel that finds no data renders an "error: snapshot stale by Ns"
  # banner — never blank. This makes silent-fail impossible (AC b).
end
```

### `.claude/hooks/enforce-parent-on-main.py` (new — invoked by `PreToolUse` on `Task`)

```python
#!/usr/bin/env python3
"""Refuse to spawn a subagent when parent repo is not on main at origin/main.

Reads `CLAUDE_PROJECT_DIR` and the JSON event on stdin. Exits 2 (= blocking
deny) with a diagnostic naming the failed invariant and the exact recovery
command. The *same script* is invoked by `.github/workflows/hygiene-sweep.yml`
so local enforcement and CI enforcement cannot drift.
"""
import json, os, subprocess, sys

def sh(cmd, **kw): return subprocess.run(cmd, capture_output=True, text=True, **kw)

def main():
    event = json.loads(sys.stdin.read())
    if event.get("tool_name") != "Task":
        sys.exit(0)
    cwd = os.environ.get("CLAUDE_PROJECT_DIR", ".")
    sh(["git", "-C", cwd, "fetch", "origin", "main"])
    branch = sh(["git", "-C", cwd, "branch", "--show-current"]).stdout.strip()
    if branch != "main":
        deny(f"Parent repo on {branch!r}, not main. Recovery: "
             f"`git -C {cwd} checkout main && git -C {cwd} pull --ff-only origin main`")
    local = sh(["git", "-C", cwd, "rev-parse", "main"]).stdout.strip()
    remote = sh(["git", "-C", cwd, "rev-parse", "origin/main"]).stdout.strip()
    if local != remote:
        deny(f"main at {local[:8]}, origin/main at {remote[:8]}. Recovery: "
             f"`git -C {cwd} pull --ff-only origin main`")
    sys.exit(0)

def deny(msg):
    print(json.dumps({"decision": "block", "reason": f"parent-on-main: {msg}"}))
    sys.exit(2)

if __name__ == "__main__": main()
```

### `.github/workflows/hygiene-sweep.yml` (new — scheduled + on-merge)

```yaml
name: hygiene-sweep
on:
  schedule: [ { cron: "*/15 * * * *" } ]    # every 15 min
  push:     { branches: [ main ] }
  workflow_dispatch:
jobs:
  sweep:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
        with: { fetch-depth: 0 }
      - name: parent-on-main invariant
        run: python3 .claude/hooks/enforce-parent-on-main.py < /dev/null
      - name: worktree cleanup invariant
        run: python3 .claude/hooks/enforce-worktree-cleanup.py
      - name: stale-branch sweep
        run: bash scripts/sweep-stale-branches.sh   # uses gh api + git push --delete
      - name: emit telemetry to ReadModel
        env: { GH_TOKEN: ${{ secrets.GITHUB_TOKEN }} }
        run: bash scripts/emit-hygiene-telemetry.sh # POSTs to a tiny webhook on tau_web
      - name: open issue on failure
        if: failure()
        uses: peter-evans/create-issue-from-file@v5
        with:
          title: "hygiene-sweep failed at ${{ github.run_id }}"
          content-filepath: ./hygiene-failure.md
          labels: hygiene, factory-v2
```

### `.github/branch-protection.json` (new — applied by `scripts/apply-branch-protection.sh`)

```json
{
  "required_status_checks": {
    "strict": true,
    "contexts": ["ci/lint", "ci/test", "ci/mutation-check", "hygiene-sweep / sweep"]
  },
  "enforce_admins": true,
  "required_pull_request_reviews": null,
  "restrictions": null,
  "allow_force_pushes": false,
  "allow_deletions": false
}
```

This makes the hygiene workflow load-bearing: a PR cannot merge until the
shared script returns green. No bespoke "merge daemon" is needed.

## Tradeoffs

### Strengths

- **Ecosystem density (root §Acceptance D).** Every non-trivial subsystem
  is reused: LiveDashboard (chrome, auth, charts), LiveView (real-time
  push), `Phoenix.PubSub` (already mandated by D-184), `:telemetry` (already
  the universal Tau telemetry transport), `:exqlite` (already a SPEC-MEMORY-
  STORE dep), `gh` CLI + GitHub Actions cron + branch-protection rules
  (no new daemons), `peter-evans/create-issue-from-file@v5` (alarm channel
  — proven in widespread CI use). The only Tau-owned new code is the
  ≤ 250-LOC projector and the ≤ 200-LOC LiveDashboard page module.
- **Single source-of-truth script.** `enforce-parent-on-main.py` and
  `enforce-worktree-cleanup.py` are the *same files* invoked by the
  Claude Code `PreToolUse` hook (local) and by the GitHub Actions workflow
  (remote). Drift between local enforcement and remote enforcement is
  structurally impossible because there is exactly one script.
- **Silent-fail impossibility (leaf AC b).** The `verdict` column is
  `NOT NULL CHECK(verdict IN ('pass','fail','checked_no_findings','infra_fail'))`;
  there is no `NULL` or `'skipped'`. A panel that finds no rows for the
  current PR renders an *error banner naming the missing input*, not a
  blank tile. This is enforced at the schema level — code that tries
  to insert a `NULL` verdict fails the SQLite CHECK.
- **Load-bearing enforcement without bespoke code (leaf AC c, d).** Branch-
  protection rules already exist as a primitive in GitHub; applying them
  makes the hygiene workflow merge-blocking. No bespoke "merge daemon"
  or coordinator self-policing is required.
- **Composable read-store.** The SQLite DB is queryable by `sqlite3`,
  `Datasette` (if a richer ad-hoc surface is wanted later), the
  LiveDashboard page, and the post-merge `main`-coherence sibling — all
  without a second copy of the data.
- **Operability for free.** LiveDashboard already provides process,
  memory, telemetry-metric, and request-logger panels; the factory panel
  joins them as one more `PageBuilder` page on the existing
  `/dev/dashboard` mount (`web/lib/tau_web/router.ex:50`).

### Weaknesses

- **LiveDashboard dev-only by default.** The current router gates
  `/dev/dashboard` on `Application.compile_env(:tau_web, :dev_routes)`;
  exposing the factory page in non-dev requires a small auth/plug story
  (basic-auth or a `Tau.Auth.Plug` token), which this proposal defers
  to the build-order step rather than solving inline. Until that lands,
  the dashboard is accessible only via `mix phx.server` locally — fine
  for a self-hosting developer factory, weaker for a multi-operator
  setup.
- **GitHub Actions cron has ~15 min skew.** GitHub schedules crons at
  best-effort intervals, so the orphan-worktree sweep can lag up to
  ~25 min in adverse conditions. PreToolUse hooks fill the gap for
  local agents; for purely-server orphans the lag is acceptable but not
  zero. (Mitigation: the `push: main` trigger ensures cleanup runs at
  every merge, so the lag only matters during quiet periods.)
- **SQLite single-writer.** The `ReadModel` GenServer is the only writer,
  per Exqlite best practice; if it crashes, projection stops until the
  supervisor restarts it. The supervised-process invariant (OTP NN #1)
  handles restart; data is reprojectable from `:telemetry` replay and
  `gh api` re-poll because the projection is pure. Still: a brief data
  staleness window exists.
- **Branch-protection requires admin token.** Applying
  `branch-protection.json` via `gh api` needs a token with `admin:repo`
  scope; this is a one-shot setup step, but it must be documented
  explicitly so the factory does not silently run without the protection
  it relies on.
- **Two languages at the hook boundary.** Hooks are Python stdlib
  (per `.claude/rules/hooks-and-scripts.md`); the dashboard is Elixir.
  The shared-script invariant means the *enforcement logic* is Python
  only; Elixir is only the read-model and view. This is a tradeoff —
  no proposal that uses Claude Code hooks can avoid it.
- **Webhook receiver in `:tau_web`.** Emitting hygiene telemetry from
  the GH Actions runner to `:tau_web` requires a small ingestion plug
  (one `POST /factory/hygiene` route). Adds a public endpoint surface
  (must be HMAC-signed). Mitigation: ship the receiver behind the same
  Auth.Plug as the dashboard, or alternatively have the Action commit
  a JSON artifact to `gh-pages` that the projector reads on its 60s
  poll — slower but zero new surface.

### Costs

- **New code:** ~250 LOC `ReadModel` + ~50 LOC `Project` + ~80 LOC
  `Schema` (migrations) + ~200 LOC `FactoryLive.Page` + ~50 LOC
  `Hygiene.scan` (Elixir) + ~120 LOC across two Python hooks + ~80 LOC
  YAML/bash workflow scripts. Total ≈ 830 LOC, of which ≈ 200 LOC are
  declarative (YAML, JSON, SQL DDL).
- **Build/dep impact:** no new Hex deps. `:exqlite`, `:phoenix_live_view`,
  `:phoenix_live_dashboard`, `:telemetry`, `:phoenix_pubsub` are
  already present (SPEC-WEB-DASHBOARD, SPEC-MEMORY-STORE). One new
  GitHub Action (`peter-evans/create-issue-from-file@v5`) is pinned by
  SHA.
- **Test surface:** property tests for `Project.apply/4` (event ->
  SQL effect is a pure function — easy `StreamData` target);
  integration test for the LiveView via `Phoenix.LiveViewTest`;
  shell-level test for the two Python hooks via the same fixture
  framework `.claude/hooks/` already uses (kill-cascade has tests).
  ~15 new test files.
- **Knowledge cost:** LiveDashboard `PageBuilder` is documented but
  not widely known; one engineer-day to internalise. Branch-protection
  JSON is well-trodden territory; ≈ 1 hour. The SQLite schema is
  intentionally narrow (6 tables) and reviewable in one sitting.
- **Operational cost:** the cron and the hooks add ~negligible compute;
  the SQLite file grows by ~1 row per gate per PR, so for the v1 rate
  (~50 PRs/month × 5 gates) the DB stays under 1 MB indefinitely.

## Dependencies

- **SPEC-WEB-DASHBOARD #374** must land first — the `:tau_web` poncho
  endpoint, router, and LiveDashboard mount provide the foundation.
  Without it, this proposal has no dashboard surface to extend. (Per
  the SPEC, the foundation PR is already scoped.)
- **`Tau.PubSub` (D-184)** must be the only `Phoenix.PubSub` instance.
  This proposal does not violate D-184 — `ReadModel` and `FactoryLive`
  both reuse `Tau.PubSub`.
- **A `[:tau, :factory, :gate, :stop]` telemetry contract** must exist:
  gates that write verdicts must `:telemetry.execute/3` an event with
  `%{pr_number, gate_id, verdict, rationale, diff_sha, evidence_url}`.
  This is owned by the **pre-merge-evidence-and-skip-integrity** sibling
  leaf; this proposal *consumes* it but does not *define* it. A `nil`
  verdict at projection time is an `infra_fail` row (silent-skip
  impossible).
- **A GitHub admin token** with `admin:repo` scope must be issued and
  stored as a repo secret to apply `branch-protection.json`. One-shot,
  documented in the build-order step.
- **`:exqlite` (already in deps tree per SPEC-MEMORY-STORE)**. No new
  Hex dep required.

## Confidence

**High**, with one caveat. Phoenix LiveDashboard PageBuilder, GitHub
branch-protection rules, GitHub Actions cron, and `gh` CLI are all
production-mature; the projector pattern (telemetry → SQLite → LiveView)
is canonical in the Elixir ecosystem (prior art: Plausible Analytics,
Sequin, LiveBeats). The caveat is that the local-vs-CI script-sharing
discipline relies on the script being deterministic enough to run in
both environments — proven for `enforce-parent-on-main.py` (pure git
incantations), less proven for `enforce-worktree-cleanup.py` if it ever
needs to inspect a running agent's worktree state. A two-day prototype
that wires one gate-stop event end-to-end (telemetry → projection →
LiveView render) would move confidence from "high with caveat" to
"high."

What would raise confidence to "very high": a small fault-injection
test that deletes a row from `gate_run` and confirms `FactoryLive`
shows the `error: snapshot stale by Ns` banner (i.e., that silent-fail
really is impossible end-to-end).

## §Build-order (adopt-first)

1. **Adopt — apply branch-protection.json via `gh api`.** No code; one
   `scripts/apply-branch-protection.sh` invocation. Makes the
   `hygiene-sweep` job load-bearing the moment it exists.
2. **Adopt — wire the two Python hooks into `.claude/settings.json`
   `PreToolUse`.** Reuse the existing hook-runner protocol (no new
   protocol surface). Hooks are read-only at this stage (`exit 0`
   always) so they cannot break local work while the projection is
   being built; flip the deny-on-fail switch in step 6.
3. **Adopt — add `.github/workflows/hygiene-sweep.yml`.** Calls the
   same two Python hooks. Starts emitting verdicts immediately;
   protected branch already requires the check to pass per step 1.
4. **Build (minimum) — `Tau.Factory.ReadModel` + `Schema`.** Just the
   SQLite write path and the `:telemetry.attach_many` on the existing
   `[:tau, ...]` events. No view. Verify rows appear via
   `sqlite3 priv/factory_state.db 'select * from gate_run'`.
5. **Build (minimum) — `TauWeb.FactoryLive.Page` over `PageBuilder`,
   mount at `/dev/dashboard/factory`.** First version reads SQLite
   directly; defer the PubSub-push wiring until step 7. AC (a) and (b)
   land here.
6. **Activate enforcement.** Flip the two Python hooks from "log-only"
   to "deny on fail" by adding the `{"decision":"block"}` JSON output.
   AC (c) lands here.
7. **Build (delta) — `PubSub` broadcast in `ReadModel.handle/4` +
   `subscribe` in `FactoryLive.mount/3`.** Real-time updates, but the
   panel was already correct (just polling) — this is a UX upgrade,
   not a correctness step.
8. **Build (delta) — `Hygiene.scan/0` Elixir function.** Calls
   `git for-each-ref`, `git worktree list --porcelain`, and
   `gh pr list --json headRefName` to populate `worktree_state` and
   `stale_branch`. AC (d) closes here.
9. **Adopt — wire `peter-evans/create-issue-from-file@v5` on
   `hygiene-sweep` failure.** Alarm channel closes; root §Acceptance E
   "actionable" requirement satisfied.
10. **Audit-finding integration.** `audit_finding` table is populated
    by the **knowledge-memory-and-audit-ingestion** sibling's registry
    writer (one shared SQLite file, two writers — only the sibling
    leaf owns the `audit_finding` table writes). This proposal *reads*
    the table for its panel; no code needed here beyond the snapshot
    query.

The build-order is adoption-front-loaded: steps 1–3 are pure config
and reuse, no Elixir code; steps 4–5 add the read model and view;
steps 6–10 are deltas. Cancelling after step 6 already satisfies the
leaf's minimum AC; later steps are quality-of-life.

## Gaps & residual risk

- **`audit_finding` write path is owned by a sibling.** This proposal
  defines the schema and reads from it but does not write to it. If
  the sibling leaf's solution chooses a different storage (e.g. flat
  YAML registry), this proposal needs a 20-LOC importer to mirror
  rows into SQLite. Track as a cross-leaf dependency.
- **Webhook ingestion path.** If the dashboard must reflect a CI
  verdict within seconds of the workflow finishing (not within 60 s of
  the next projector poll), a small `POST /factory/hygiene` plug is
  required. This proposal defers that to a future delta; the 60-s
  poll satisfies the leaf's AC ("automatically populated").
- **First-mover dependency on SPEC-WEB-DASHBOARD #374.** If #374
  slips, this proposal can ship steps 1–3 (which need no Elixir at
  all) and step 4 (which only needs `:tau` core + `:exqlite`),
  reading via `sqlite3 priv/factory_state.db` and `Datasette` until
  the LiveView surface is ready. Degraded mode, not blocked.
- **Silent-skip impossibility relies on the gate emitting a row.** A
  gate that crashes before any `:telemetry.execute/3` would leave no
  row at all — which the projector flags as `infra_fail` only when
  the PR's open-status is queried (the snapshot computes "expected
  gates" from `pr_state.declared_acs` and emits a stale-row error
  if any expected gate has no `gate_run`). This is the correct
  behaviour — gates that don't emit are visible by their absence —
  but the *enforcement* of "no merge while any expected gate row is
  missing" lives in the **pre-merge-evidence-and-skip-integrity**
  sibling, not here. Cross-leaf coupling documented.

## Prior art / references

- **Phoenix LiveDashboard `PageBuilder` behaviour** — the established
  pattern for adding custom dashboard pages
  (https://hexdocs.pm/phoenix_live_dashboard/Phoenix.LiveDashboard.PageBuilder.html).
  Used in production by Plausible Analytics, Sequin, LiveBeats.
- **SPEC-WEB-DASHBOARD (`docs/spec/SPEC-WEB-DASHBOARD.md`)** — the
  Tau-internal contract this proposal extends; D-180..D-189 mandate
  the mount-replay-subscribe pattern this proposal follows.
- **`web/lib/tau_web/router.ex:50`** — the existing LiveDashboard
  mount point at `/dev/dashboard`. This proposal adds one more page
  to it.
- **`web/lib/tau_web/telemetry.ex`** — the existing telemetry-metric
  pipeline; this proposal adds events to the same `[:tau, ...]`
  namespace it consumes.
- **GitHub branch-protection rules API**
  (https://docs.github.com/en/rest/branches/branch-protection) — the
  primitive that makes the workflow's verdict load-bearing without
  any bespoke daemon. Universally adopted; `gh api` is the canonical
  client.
- **`peter-evans/create-issue-from-file@v5`** — the most widely-used
  GitHub Action for opening issues on workflow failure. ~30k stars
  across dependent repos.
- **`.claude/hooks/kill-cascade.py`** — Tau's existing precedent for
  `PreToolUse` Python hooks; the two new hooks follow the same
  pattern, share the same test harness, and obey the same Python-
  stdlib-only rule (`.claude/rules/hooks-and-scripts.md`).
- **`.claude/rules/worktree-discipline.md`** — the prose rule this
  proposal mechanises. The two hooks encode invariants currently
  documented only in prose.
- **Plausible Analytics** — production reference for the projection
  pattern (telemetry → SQLite → LiveView) at scale
  (https://github.com/plausible/analytics).
- **Datasette** (https://datasette.io/) — optional adopt-only
  surface for ad-hoc SQL over `factory_state.db`; named here so
  the design leaves the door open without committing to it.
