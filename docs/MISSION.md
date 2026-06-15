# Tau — Mission

A working TUI: `./burrito_out/tau_linux_<arch>` in a real terminal renders
the interface, completes a single user → assistant turn against a real
provider, and quits cleanly. This is the prerequisite for Tau replacing the
vendored claude-harness as the dev tool for Tau itself — the self-hosting
milestone.

Work that does not advance an acceptance criterion of
`docs/spec/SPEC-USER-TURN.md` or eliminate a known blocker is not the
priority.

## Source of truth for "working"

`docs/spec/SPEC-USER-TURN.md` defines the user-turn loop's constraints,
runtime invariants (`D-NNN`), and acceptance criteria (`AC-N`). Each
invariant carries a detection method naming the file or test that enforces
it. Each AC carries a pass/fail criterion that lives in a check, not in
this file.

## Where state lives

Per [ADR-0023](adr/0023-documentation-taxonomy.md), durable docs (including
this one) describe intent and contracts, not state. The questions a fresh
agent asks belong to systems of record:

| Question | Answer |
|---|---|
| What's the current milestone state? | `gh api 'repos/{owner}/{repo}/milestones?state=all'` |
| What's open / what's broken? | `gh issue list --state open` |
| Does the TUI work? | CI's `binary-qa` job; specifically `mix tau.tui_ux` (tmux-driven pty against the Burrito binary). |
| Does the coordinator pipeline work end-to-end? | CI's `binary-qa` Layer F (`test/tau/qa/coordinator_roundtrip_test.exs`). |
| What's the latest test count? | The CI run's job output. |
| Which branches are live? | `git branch -a`. |

Durable docs MAY link to these systems; they MAY NOT copy snapshots from
them.

## Where design lives

- **`docs/spec/SPEC-*.md`** — component contracts.
- **`docs/adr/`** — accepted architectural decisions.
- **`CLAUDE.md` / `TAU.md` / `.claude/rules/`** — coordinator rules.
- **`docs/PROJECT.md`** — repo layout.
- **`docs/adr/0023-documentation-taxonomy.md`** — what kind of documentation
  lives where (read first if you're considering authoring durable docs).

## D-NNN namespace

D-NNN identifiers are runtime invariants defined in SPECs. The namespace is
partitioned; each SPEC manages its own block. Before authoring a new
D-NNN, verify the identifier is free across the whole repo:

```sh
git log --all --grep="D-NNN-VALUE" --oneline
grep -rn "D-NNN-VALUE" lib test docs .claude
```

Single-branch negative results are not evidence of absence — the repo has
had multiple branches with significant divergent work, and the working
tree of any one branch is not authoritative.

Block-to-SPEC allocation:

| Block | Owner SPEC |
|---|---|
| D-001 – D-028 | SPEC-USER-TURN — core session FSM invariants |
| D-029, D-030, D-043, D-044 | SPEC-CIRCUIT-BREAKER |
| D-031 – D-039, D-375 | SPEC-CODING-AGENT |
| D-040 – D-042, D-048, D-049, D-056, D-058 – D-062, D-076 – D-089 | SPEC-USER-TURN — amendments |
| D-045 – D-047 | SPEC-MEMORY-STORE |
| D-050 – D-055, D-057 | SPEC-OTEL-REPORTER |
| D-063 – D-065 | SPEC-PROMPT-CACHING |
| D-066 – D-075, D-140 – D-169 | SPEC-TUI-HEADLESS |
| D-090 – D-099, D-170 – D-179 | SPEC-PERMISSION-PROMPTS |
| D-100 – D-109 | SPEC-TUI-COMPLETION |
| D-110 – D-119 | reserved — SPEC-SESSION-MANAGEMENT (not yet authored) |
| D-120 – D-129 | SPEC-EXTENSIONS |
| D-130 – D-139 | reserved — SPEC-CLUSTER (future) |
| D-180 – D-189 | SPEC-WEB-DASHBOARD |
| D-300 – D-303, D-341 | SPEC-FACTORY-MERGE |
| D-304 – D-308, D-322, D-323, D-354 | SPEC-FACTORY-GATE |
| D-309 – D-311, D-313, D-314, D-316, D-334, D-364 – D-367, D-376, D-381, D-382 | SPEC-FACTORY-FLEET |
| D-312, D-315, D-317, D-318, D-320, D-321, D-330 – D-333, D-335, D-336, D-340, D-342 – D-344, D-355 – D-359, D-369 – D-373, D-380 | SPEC-FACTORY-CORE |
| D-319, D-351 – D-353, D-374 | SPEC-FACTORY-GOV |
| D-361 – D-363 | SPEC-FACTORY-CORE (C1 unit-coordinate identity; PR #503) |
| D-377 – D-379 | reserved — SPEC-FACTORY-GOV (heartbeat-driven Unit liveness; unmerged `feat/491-heartbeat-timeout`, #491) |
| D-300 – D-385 | reserved — SPEC-FACTORY-\* family (autonomous factory; `docs/arch/`) |

A SPEC needing a D-NNN outside its allocated block MUST update this table
in the same change.

## How to read this file as a fresh agent

1. This file first.
2. `docs/spec/SPEC-USER-TURN.md` — the user-turn loop SPEC.
3. `docs/adr/0023-documentation-taxonomy.md` — the documentation rules.
4. `CLAUDE.md` and `TAU.md` — coordinator config.
5. `docs/PROJECT.md` — repo layout.

Do not author a new SPEC, ADR, or D-NNN before reading these.
