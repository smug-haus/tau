# Work-record schema (v1)

Each file `.claude/work-records/<record-id>.json` captures one end-to-end
operator interaction on a single task. Records are append-only by
convention: each role appends its block when it runs; `human_action` is
filled in retrospectively when you act on the PR.

The record is the **only** signal source the project adapter
(`.claude/hyperagents-eval/role_eval.py`) reads to score a sibling's
candidates. Anything you want the meta-agent to mutate against must
end up here.

## Path & id

`.claude/work-records/wr-<UTC-yyyymmddThhmmss>-<short-hash>.json`

## Shape

```json
{
  "version": 1,
  "record_id": "wr-20260513T1812-7f3a",
  "created_at": "2026-05-13T18:12:00Z",

  "task": {
    "kind": "issue | curated | hyperagents-task",
    "source": "github | hand-curated | derived-from-purpose",
    "issue_number": 143,
    "title": "...",
    "url": "https://github.com/smug-haus/tau/issues/143",
    "body": "the prompt text the operators receive"
  },

  "implementer": {
    "gen_id": "tau-implementer/gen4-a7175c7a",
    "scratch_id": null,
    "branch": null,
    "diff": "unified diff text",
    "files_changed": ["lib/tau/..."],
    "stdout_excerpt": "first ~2KB of operator stdout",
    "wall_clock_s": 0.0,
    "tokens": 0,
    "completed_at": "..."
  },

  "critic": {
    "gen_id": "tau-critic/gen5-a7175c7a",
    "findings": [
      {
        "id": "f-1",
        "severity": "BLOCKING | SUGGESTION",
        "category": "spec-deviation | otp-non-negotiable | over-engineering | scope-creep | other",
        "file": "lib/tau/session.ex",
        "line": 142,
        "message": "...",
        "evidence": "quoted code or spec excerpt"
      }
    ],
    "single_most_important_id": "f-1",
    "wall_clock_s": 0.0,
    "tokens": 0,
    "completed_at": "..."
  },

  "reviewer": {
    "gen_id": "tau-reviewer/gen7-a7175c7a",
    "verdict": "PASS | FAIL | PARTIAL",
    "tests":  { "tool": "mix test", "passed": 360, "failed": 0, "errors": 0 },
    "format_clean": true,
    "credo_clean": null,
    "findings": [ "same shape as critic.findings" ],
    "evidence": "...",
    "wall_clock_s": 0.0,
    "tokens": 0,
    "completed_at": "..."
  },

  "human_action": {
    "action": "merged | revision_requested | rejected | abandoned",
    "actor": "brentw",
    "at": "...",
    "pr_url": null,
    "addressed_finding_ids":   ["f-1", "f-3"],
    "ignored_finding_ids":     ["f-2"],
    "fabricated_finding_ids":  ["f-4"],
    "rationale": "free-form note"
  }
}
```

## Field semantics — the bits load-bearing for the loop

- `implementer.diff` / `files_changed` / `stdout_excerpt`: the artefact
  critic and reviewer review. Required for any scoring downstream of
  the implementer.
- `critic.findings[].id`: stable identifier referenced by
  `human_action.addressed_finding_ids` / `ignored_finding_ids` /
  `fabricated_finding_ids`. The critic's score depends on this.
- `critic.findings[].severity`: `BLOCKING` findings are the hard
  signal; `SUGGESTION` findings are graded more leniently (a noisy
  critic is more painful for blocking findings than suggestions).
- `reviewer.verdict` + `reviewer.tests`: the reviewer's score is its
  *calibration* against what `mix test` actually said + what the
  human eventually did. A `PASS` verdict on a PR the human rejected,
  or a `FAIL` verdict on one the human merged, are both miscalibrations.
- `human_action.*_finding_ids`: the ground-truth labels for critic's
  per-finding accuracy. `addressed` = real; `ignored` = ignorable;
  `fabricated` = wrong / nonsense (the critic's bullshit-finding rate).

## Lifecycle

1. `implementer` role runs → file created with `task` and `implementer`
   blocks populated; other blocks `null`.
2. `critic` role runs → reads records where `implementer != null` and
   `critic == null`; appends `critic` block.
3. `reviewer` role runs → reads records where `implementer != null` and
   `reviewer == null`; appends `reviewer` block.
4. PR is opened (manually or by tooling); the operator chain's record
   is referenced.
5. Human acts on PR → `human_action` block is filled in (by hand, or
   by tooling that watches `gh pr` state).

## Adapter contract

`role_eval.py` reads work-records, scores the candidate, and writes
`scores.json` per `hyperagents:eval-adapter-spec`. The `metrics`
channel is the project's open channel to the meta-agent's prompt —
emit anything you want the meta-agent to be able to reason over.
