# SubagentStop Prompt Hook: Evaluate Completion

This file documents the prompt used by the SubagentStop `type: prompt` hook
in `.claude/settings.json`. The actual prompt is inline in settings.json;
this file serves as the reference and maintenance copy.

## Prompt

> Review the subagent's completion claim. Check: (1) Were tests run
> (`mix test`) and do they pass? (2) Was `mix format --check-formatted`
> run? (3) Is the implementation actually complete, or is the agent
> stopping early? (4) Are there hardcoded values, TODOs, or silent
> failures? If the work is incomplete, state specifically what remains.

## Rationale

This prompt runs as a Haiku-level quality gate when any subagent attempts
to complete. It catches:

- **Premature completion**: Agent declares "done" before all spec items
  are implemented.
- **Missing test execution**: Agent claims tests pass without running them.
- **Superficial fixes**: Hardcoded values, TODOs, or error-swallowing code
  that masks incomplete work.

The command hook (`check-tests-pass.sh`) handles deterministic checks
(do tests actually pass?). This prompt hook handles judgment calls
(is the completion claim credible?).

## Scoped Variants

The critic and reviewer subagents have their own SubagentStop prompt hooks
defined in their YAML frontmatter (`.claude/agents/critic.md` and
`.claude/agents/reviewer.md`). Those hooks evaluate the quality of the
critic's feedback and reviewer's evaluation respectively, not the
implementation work itself.
