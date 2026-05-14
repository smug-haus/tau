# Tau — Mission and current state

> Read this file before authoring anything else in this repo. It is the
> alignment artifact that exists because a prior agent (2026-05-04) burned
> a session re-doing PSDH work that was already done. The failure log at
> the bottom is the rule that produced this file — read it first if you
> are new.

## Mission

A working TUI: `./burrito_out/tau_linux_<arch>` in a real terminal renders
the interface, completes a single user → assistant turn against a real
provider, and quits cleanly. This is the prerequisite for Tau replacing
the vendored claude-harness as the dev tool for Tau itself — i.e. for the
1.0 self-hosting milestone.

The user has been explicit: this is the priority. PSDH method, ADRs,
heuristic catalogs, telemetry — all of it serves this goal. Work that
does not advance an acceptance criterion below or eliminate a known
blocker is not the priority.

## Source of truth for "working"

`docs/spec/SPEC-USER-TURN.md` defines:

- 43 boundary constraints (`[Cn-Bm]`, 24 marked non-obvious).
- 20 runtime invariants (`D-001`–`D-019` plus `D-027`; `D-005` superseded by `D-027`) with detection methods.
- 7 acceptance criteria (`AC-1`–`AC-7`).
- A source map (Appendix B) tying constraints to file:line.

That file currently lives on branch `spec/user-turn-loop`, **not on main
and not on `feat/anthropic-oauth`**. The branch state is split-brain
(see below). Do not assume the SPEC has been read by all branches just
because commit messages reference D-NNN identifiers — they reference a
file the branch may not contain.

The companion rule `.claude/rules/spec-before-code.md` (also on
`spec/user-turn-loop`) names this SPEC as the gate for any PR touching
`lib/tau/cli.ex`, `lib/tau/tui/`, `lib/tau/session.ex`,
`lib/tau/application.ex`, `lib/tau/providers/*` (in `stream/3`), or
`lib/tau/settings/cache.ex`.

## Verified state (2026-05-04, this session, by direct observation)

| Check | Method | Result |
|---|---|---|
| Binary exists | `ls burrito_out/` | `tau_linux_arm64` (aarch64 ELF, static) |
| Binary launches | `tau_linux_arm64 --help` | subcommand list prints |
| Non-TUI roundtrip | `tau_linux_arm64 run "ping" --provider replay --model replay` | stdout: `(replay) hello` |
| Mix test suite | `mix test` | 350 tests, 35 properties, 0 failures, 2 skipped |
| Inotify warning | observed at every binary launch | environmental (WSL2 / no inotify-tools); not a Tau bug |

The non-TUI codepath end-to-end (binary → CLI dispatch → app boot →
session FSM → provider stream → stdout) **works**. AC-5 passes.

## Not verified — the actual gap

- **AC-1 (first-run TUI smoke):** requires a real TTY. Cannot be checked
  in a non-interactive session. Issue #153 documents prior breakage
  (`Ratatouille.EventManager not started`). Commits af9df00 (start
  Ratatouille via `Tau.TUI.Supervisor`) and 834dd3c (D-009 / D-002 / D-004
  first-turn visibility fixes) target the symptom. Whether the TUI now
  actually renders + completes a turn in a terminal is what the user
  reports as still broken.
- **AC-2, AC-3, AC-4, AC-7:** all require a TTY.
- **AC-6 (tool-iteration safety):** SPEC §6 D-005 detection method is
  unimplemented as of feat/anthropic-oauth tip.

## Branch state (verified via `git rev-list --count`)

| Branch | ahead of main | has SPEC | has TUI fixes | has OAuth |
|---|---:|:---:|:---:|:---:|
| `main` | 0 | no | no | no |
| `spec/user-turn-loop` | 18 | **yes** | partial (shared base) | (amendment ref only) |
| `feat/anthropic-oauth` (current) | 21 | **no** | yes (5 new commits) | yes |

Both branches diverged from commit `9830703` (PR #152 merge). Neither has
been merged to main. The OAuth branch's commits cite SPEC identifiers
(`D-017/D-018/D-019`, `D-009`, `D-002`, `D-004`) but do not contain the
SPEC document. Whoever authored those commits read the SPEC from
elsewhere.

## D-NNN namespace — claimed range

The runtime-invariant namespace is defined in `SPEC-USER-TURN.md` §6:

```
D-001 … D-019  taken (SPEC-USER-TURN.md)
D-020 … D-025  taken (SPEC-TUI-HEADLESS.md)
D-026           free
D-027           taken (SPEC-USER-TURN.md — tool-iteration cap, AC-6)
D-028 +        free
```

References to D-NNN appear across `lib/tau/`, `test/tau/`, commit messages,
and code comments. **Do not reuse a taken identifier.** Before authoring
a new D-NNN, run:

```sh
git log --all --grep="D-NNN" --oneline
grep -rn "D-NNN" lib test docs .claude
```

Both must return empty for a number to be considered free.

## Open issues blocking the mission

- **#153** — bug: TUI broken in prod / Burrito binary — Ratatouille.EventManager not started.
- **#149** — test: delivery layer (TUI runtime, CLI dispatch, release/Burrito boot) is uncovered.
- **#155** — test(blocking-gate): single binary smoke test — `tau run --provider replay` must produce stdout. (Likely closeable: AC-5 codepath verified above.)

## Action ladder for the next session

1. **Run the TUI in a real terminal.** `./burrito_out/tau_linux_<arch>`
   (no args defaults to `tui`). The user is doing this and it does not
   work. Triage by what fails first: launch crash, blank render, input
   not echoed, no provider response, can't quit, can't restart.
2. **Document the failure mode against AC-1 / AC-2 / AC-3 / AC-4** — each
   AC has explicit pass/fail conditions in `SPEC-USER-TURN.md` §7. Naming
   which AC fails grounds the next fix.
3. **Decide the merge plan for the two divergent branches.** Both are
   ahead of main; one carries the SPEC, the other carries the OAuth +
   TUI fixes. Until they converge, the source-map references in the SPEC
   will keep going stale relative to the implementation branch.
4. **Only after the TUI works end-to-end** revisit D-NNN coverage gaps
   (AC-6 D-005, the deferred-hazard list in §8).

## How to read this file as a fresh agent

1. This file first.
2. `docs/spec/SPEC-USER-TURN.md` (from branch `spec/user-turn-loop` if
   not yet on main): §0 (why this exists), §6 (D-NNN catalog), §7 (AC).
3. `docs/PROJECT.md` for the high-level layout.
4. `CLAUDE.md` + `TAU.md` for coordinator config and OTP non-negotiables.

Do not author a new SPEC, ADR, or D-NNN heuristic before reading those.
The user-turn loop is the most thoroughly PSDH-analyzed component in the
project; the work to do is acceptance, not redesign.

## Failure log — 2026-05-04 session

A prior agent (me) was given the directive: scan the project for
PSDH-eligible components, critique them, and build out heuristics that
steer toward 1.0 self-hosting. The agent:

1. Did not check whether prior PSDH work existed before authoring.
2. Authored a parallel `D-001`–`D-012` "heuristic catalog" at
   `heuristics/design/` — colliding with the existing `D-001`–`D-019`
   namespace in `SPEC-USER-TURN.md`.
3. Made multiple confident factual claims that turned out wrong:
   - "SPEC-USER-TURN.md doesn't yet exist" (it did, on another branch).
   - "D-NNN namespace is free" (19 deep, actively used in code).
   - "Agent tool is unbuilt" (it exists at
     `lib/tau/tools/builtin/agent.ex`, ~484 LOC).
   - "D-009 is the documented blocker, unimplemented" (already enforced
     via `test/tau/session/sync_provider_error_test.exs`).
4. Reverted the colliding catalog only after a `git log` search surfaced
   the namespace conflict.

Net delivery for the session: zero artifacts retained, working tree
clean, several hours of conversation burnt.

**Rule extracted:** before authoring any artifact that names a concept,
file, identifier, or invariant, verify the name is free across **all
branches and the entire repo**, not just the current branch / current
working tree. Negative results from `find` on the current branch are not
evidence of absence. Mandatory checks:

```sh
git log --all --grep="<concept>" --oneline
git log --all -- "<expected-path>"
grep -rn "<identifier>" lib test docs .claude
```

If any of those returns content, the concept is in use. Read it before
authoring.

A second rule extracted from the same session: confident assertion based
on a single negative search is a recurring failure mode in this repo.
The repo has multiple branches with significant divergent work; the
working tree of any one branch is not authoritative for "what exists in
this project."
