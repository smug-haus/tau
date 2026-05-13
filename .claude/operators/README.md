# Operators manifest

Each `<role>.id` file contains one line — `<sibling-name>/<gen-id>` —
naming the currently-promoted hyperagent for that role.

The line is a path relative to `.claude/hyperagents/`. To invoke the
operator, resolve to `.claude/hyperagents/<sibling-name>/agents/<gen-id>/`
and run `claude --plugin-dir <that-path>` (or `claude -p --plugin-dir
<that-path>` headless).

Promotion is a human-gated step: bump the gen-id here only after reading
the diff between the currently-promoted gen and the candidate gen in
`.claude/hyperagents/<sibling>/agents/`. Don't trust the hyperagents
score blindly — it grades against the eval task set, not necessarily
against tau's real backlog distribution.

## Current operators

- `implementer.id` → `tau-implementer/gen4-a7175c7a`
- `critic.id`      → `tau-critic/gen5-a7175c7a`
- `reviewer.id`    → `tau-reviewer/gen7-a7175c7a`

(Update by hand. Format = single line, no trailing newline interpreted as
content. Anything after a `#` on the line is treated as a comment.)
