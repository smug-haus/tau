# M1 Verification Runbook

## 1. Purpose

This runbook is the final step of milestone M1 (self-hosting). All autonomous
prerequisites have shipped: the FSM-backed `tau run` (PR #253), the olog
(PR #254), and the coordinator + sub-persona skills (PR #257). What remains is
a single end-to-end verification: a Tau coordinator session takes a real
roadmap issue from open to a gate-passed, merged PR with **no Claude Code or
external harness in the loop**. Success criterion: one merged PR whose entire
authoring pipeline — issue selection, implementer spawn via `Agent`, critic +
reviewer gate, `gh pr merge`, post-merge health check — ran inside a single
`tau run` invocation.

## 2. Prerequisites

**Toolchain.** Versions are pinned in `.tool-versions`:

- Erlang/OTP 27.2
- Elixir 1.18.1-otp-27

Verify:

```
elixir --version   # should report Elixir 1.18.1 (compiled with Erlang/OTP 27)
mix --version      # should report Mix 1.18.1
```

If either is wrong, run the `tau-toolchain` install skill or follow
`setup.sh`.

**Working tree.** Must be on `main` at `origin/main` with a clean status:

```
git fetch origin
git checkout main
git pull --ff-only origin main
git status --short   # must be empty
```

**Build.** Confirm `main` is green before starting:

```
mix compile --warnings-as-errors
mix test
```

**GitHub CLI.** Must be authenticated and able to push branches and open PRs
against `smug-haus/tau`:

```
gh auth status         # should show "Logged in to github.com"
gh repo view smug-haus/tau --json name   # must succeed
```

If not authenticated: `gh auth login`.

**Provider credential.** See §3 below.

## 3. Provider setup

### Recommended: Anthropic (API key)

Anthropic is the recommended provider for M1 verification. It has the most
complete tool-use support in this codebase (capabilities include tools,
parallel tools, vision, prompt caching, thinking) and the implementation is the
most battle-tested.

Set the environment variable:

```
export ANTHROPIC_API_KEY=sk-ant-...
```

Tau resolves this via the vault default (`ANTHROPIC_API_KEY` env var). Verify
before running:

```
tau doctor   # should report: provider Tau.Providers.Anthropic: api_key (env / settings)
```

**Alternative: Claude Code OAuth.** If you have a Claude Pro/Max subscription
and Claude Code is installed, you do not need an API key. Tau will automatically
use the OAuth token from `~/.claude/.credentials.json`. If the token is expired,
run `claude /login` to renew. `tau doctor` reports the OAuth status and TTL.

**Other providers.** The following providers are supported but not recommended
for a first verification run. Credential mechanism in parentheses:

| Provider | Flag | Credential |
|---|---|---|
| OpenAI | `--provider openai` | `OPENAI_API_KEY` env var |
| Gemini | `--provider gemini` | `GEMINI_API_KEY` env var |
| Bedrock | `--provider bedrock` | AWS credentials (standard SDK chain) |
| Copilot | `--provider copilot` | OAuth via `gh auth login --scopes copilot` |
| DeepSeek | `--provider deepseek` | `DEEPSEEK_API_KEY` env var |
| Groq | `--provider groq` | `GROQ_API_KEY` env var |
| Mistral | `--provider mistral` | `MISTRAL_API_KEY` env var |
| Azure OpenAI | `--provider azure` | `AZURE_OPENAI_API_KEY` + `AZURE_OPENAI_ENDPOINT` + `AZURE_OPENAI_DEPLOYMENT` |

All non-Anthropic providers require that the chosen model supports tool use.
Verify before using.

## 4. The invocation

Build Tau first (or use the compiled escript if already built):

```
mix escript.build
```

Then run:

```
./tau run "$(cat docs/m1-verification/smoke-task.md | grep -A200 'Verbatim smoke-task prompt' | tail -n +3 | sed 's/^```$//' | grep -v '^```')" \
  --system-prompt-file priv/skills/tau-coordinator/SKILL.md \
  --provider anthropic \
  --model claude-opus-4-7
```

Or, more readably, store the prompt in a shell variable first:

```
SMOKE_PROMPT=$(cat docs/m1-verification/smoke-task.md | \
  awk '/^```$/{if(p)exit; p=1; next} p' | head -n -1)

./tau run "$SMOKE_PROMPT" \
  --system-prompt-file priv/skills/tau-coordinator/SKILL.md \
  --provider anthropic \
  --model claude-opus-4-7
```

The exact verbatim prompt text is in `docs/m1-verification/smoke-task.md` §
"Verbatim smoke-task prompt". Copy it and pass it as the positional `<prompt>`
argument. The full literal command with the prompt inline is:

```
./tau run \
  'You are the Tau coordinator. Execute one factory step for issue #258.

Issue #258 is open on smug-haus/tau. Title: "fix(skills): namespace collision —
generic persona names can be masked by user skills". The issue documents that the
bundled coordinator sub-personas (implementer, critic, reviewer under priv/skills/)
share generic names that a user skill at ~/.tau/skills/ can silently shadow,
breaking the M1 factory loop.

Execute the factory cycle for this issue end-to-end:

1. Check for .claude/STOP-FACTORY — halt if present.
2. Confirm issue #258 is open on smug-haus/tau (gh issue view 258).
3. Verify git is on main at origin/main (git fetch origin; git rev-parse main
   vs git rev-parse origin/main). Branch: git checkout -b fix/skill-namespace-258.
4. Spawn an implementer Agent to implement option (1)+(2) from the issue:
   - Rename priv/skills/implementer/ to priv/skills/tau-implementer/ (and critic,
     reviewer analogously).
   - Update all subagent_type references in priv/skills/tau-coordinator/SKILL.md
     from "implementer"/"critic"/"reviewer" to "tau-implementer"/"tau-critic"/"tau-reviewer".
   - Add a Logger.warning in Tau.Skills.Loader.discover/1 when a priv/skills
     entry is shadowed by a same-named user skill.
   - Add a test that asserts the bundled personas remain reachable when a
     same-named user skill exists in ~/.tau/skills/.
   - Run mix compile --warnings-as-errors and mix test to confirm green.
   - Commit and push the branch; open a PR with gh pr create referencing
     Closes #258.
5. Run the FULL gate: spawn a critic Agent (read the diff with git diff
   origin/main...HEAD; return {"ok": true} or {"ok": false, "reason": "..."} as
   the last JSON line). Then spawn a reviewer Agent (same diff, same contract).
   Both must return {"ok": true} to proceed.
6. If gate is green: gh fetch origin; confirm origin/main is unchanged; then
   gh pr merge <n> --merge --delete-branch.
7. Sync: git fetch origin && git checkout main && git pull --ff-only origin main.
8. Health check: mix compile --warnings-as-errors && mix test. Report results.
9. Report: state the merged PR number and SHA, confirm M1 factory cycle
   completed successfully, and that #258 is now closed.' \
  --system-prompt-file priv/skills/tau-coordinator/SKILL.md \
  --provider anthropic \
  --model claude-opus-4-7
```

## 5. The smoke task

The smoke task drives the coordinator through the full factory cycle for issue
#258 (skill namespace collision). See `docs/m1-verification/smoke-task.md` for
the full prompt text and the rationale for choosing #258 over #259.

Verbatim prompt (also in `smoke-task.md`):

> You are the Tau coordinator. Execute one factory step for issue #258.
>
> Issue #258 is open on smug-haus/tau. Title: "fix(skills): namespace collision —
> generic persona names can be masked by user skills". ...
>
> *(see `docs/m1-verification/smoke-task.md` for the full text)*

## 6. What to watch for

The session writes one JSONL record per event to
`~/.tau/sessions/<cwd-hash>/<session-id>.jsonl`. Observable milestones, in
order:

1. **`session_header`** — first record in the JSONL file. Contains `session_id`,
   `cwd`, `provider`, `model`. Confirms the FSM started and persistence is
   working.

2. **Coordinator first assistant turn** — an `assistant_message` record with
   text output confirming the coordinator has read the persona and begun the
   factory cycle.

3. **`tool_call` for `Bash`** — coordinator runs `gh issue view 258` and `git
   fetch origin` to verify preconditions.

4. **`tool_call` for `Agent`** (`subagent_type: "implementer"`) — coordinator
   spawns the implementer child session. This is the critical M1 signal: the
   coordinator is using `Tau.Tools.Builtin.Agent` to drive a sub-session, not
   calling Claude Code.

5. **Child `session_header`** — a second JSONL file (different `session_id`)
   appears under the same cwd-hash directory. The implementer child is running.

6. **`tool_result`** for the implementer `Agent` call — the implementer has
   completed and returned its result text to the coordinator.

7. **`tool_call` for `Bash`** — `gh pr create` is called. A real PR number
   appears in the tool result.

8. **`tool_call` for `Agent`** (`subagent_type: "critic"`) — gate, first half.

9. **`tool_result`** for critic — last JSON line of the result is
   `{"ok": true}` (or `{"ok": false, "reason": "..."}` on failure).

10. **`tool_call` for `Agent`** (`subagent_type: "reviewer"`) — gate, second half.

11. **`tool_result`** for reviewer — last JSON line is `{"ok": true}`.

12. **`tool_call` for `Bash`** — `gh pr merge <n> --merge --delete-branch`.

13. **`tool_call` for `Bash`** — `git fetch origin && git checkout main && git
    pull --ff-only origin main` (sync).

14. **`tool_call` for `Bash`** — `mix compile --warnings-as-errors && mix test`
    (post-merge health check).

15. **`assistant_message`** (final) — coordinator's summary reporting the merged
    PR, SHA, and confirmation that M1 factory cycle completed. `stop_reason:
    :end_turn` or `:stop`.

16. **`session_end`** — clean exit. `tau run` exits with code 0.

You can tail the JSONL in real time:

```
SESSION_DIR=~/.tau/sessions
LATEST=$(ls -t "$SESSION_DIR"/*/*.jsonl 2>/dev/null | head -1)
tail -f "$LATEST" | while IFS= read -r line; do
  echo "$line" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('kind',''), d.get('data',{}))" 2>/dev/null || echo "$line"
done
```

## 7. Success criteria

All four conditions must hold:

a. **A PR with a real diff exists and is merged** on `smug-haus/tau`. Verify:
   `gh pr view <n> --json state,mergedAt,mergeCommit` shows `state: MERGED`.

b. **The merge happened from inside the Tau session**, not from Claude Code or
   the user's shell. Evidence: the JSONL transcript shows a `tool_call` record
   with `tool: "Bash"` and `input` containing `gh pr merge`. The timestamp of
   that record is within the session window.

c. **The JSONL transcript shows the coordinator-only flow.** The parent session's
   JSONL file contains `tool_call` records for `Agent` (with `subagent_type:
   "implementer"`, `"critic"`, and `"reviewer"`) and the corresponding
   `tool_result` records. There is no Claude Code process in the process tree.

d. **`main` health-checks green after the merge.** Run from the repo root after
   the session exits:
   ```
   mix compile --warnings-as-errors
   mix test
   ```
   Both must exit 0.

## 8. Captured evidence

After a successful run, commit the following under `docs/m1-verification/evidence/`:

1. **Merged PR URL.** A one-line text file: `evidence/merged-pr.txt` containing
   the GitHub PR URL.

2. **Merge commit SHA.** `evidence/merge-sha.txt` containing the output of
   `git rev-parse origin/main` immediately after the sync step.

3. **Parent-session JSONL.** Copy the coordinator's JSONL file:
   ```
   cp ~/.tau/sessions/<cwd-hash>/<session-id>.jsonl \
      docs/m1-verification/evidence/parent-<short-sha>.jsonl
   ```
   where `<short-sha>` is the first 7 characters of the merge commit SHA.

4. **Summary note.** `evidence/<short-sha>-summary.md` containing:
   - Provider and model used.
   - Total session duration (wall time).
   - Number of `tool_call` records in the parent JSONL (coordinator turns).
   - Number of child session JSONL files created (one per sub-agent).
   - Any notable observations (gate failures encountered and resolved, etc.).

Commit these files on `main` with message:
`docs(m1): record verification evidence (closes #256)`.

## 9. Failure modes and debugging

**Coordinator cannot resolve `subagent_type: "implementer"`**
- Symptom: coordinator's first `Agent` call returns `is_error: true` with a
  message like "skill not found: implementer".
- Cause: a user skill at `~/.tau/skills/implementer/SKILL.md` is shadowing the
  bundled persona (issue #258 — ironically the very thing we are fixing).
- Remediation: temporarily rename or remove `~/.tau/skills/implementer/` and
  re-run. File the rename under a different name.

**Tau exits 1 — missing provider key**
- Symptom: `tau run` immediately prints `system-prompt error: ...` or `session
  start error: missing_api_key` and exits 1 before any JSONL is written.
- Diagnostic: `tau doctor` — check the Anthropic line.
- Remediation: `export ANTHROPIC_API_KEY=sk-ant-...` and retry.

**`gh` not authenticated**
- Symptom: coordinator's `gh issue view 258` tool call returns an error like
  "authentication required".
- Diagnostic: `gh auth status`.
- Remediation: `gh auth login`.

**Coordinator exits early — OAuth token expired**
- Symptom: session ends with `stop_reason: :error` and message "Your Claude
  Code OAuth token expired; run `claude /login` to renew."
- Remediation: `claude /login` to refresh, then retry.

**Smoke task too complex — coordinator hits tool loop limit**
- Symptom: session exits with `stop_reason: :tool_loop_aborted`.
- Cause: the coordinator entered a retry loop (e.g. implementer gated, repeated
  refine attempts) that exhausted the tool-iteration cap.
- Remediation: simplify the prompt to a narrower scope; or increase the tool
  loop cap in settings if it has been configured lower than the default.

**Gate fails — implementer's work does not pass critic or reviewer**
- Symptom: coordinator reports `{"ok": false, "reason": "..."}` from critic or
  reviewer, enters refine cycle.
- This is expected coordinator behaviour. Watch whether the coordinator
  successfully drives a second implementer pass and re-runs the gate. If it
  reaches N = 3 failures and escalates to the user, that is also correct
  behaviour — report the gate findings as the failure mode.

**`mix test` fails in post-merge health check**
- Symptom: coordinator reports red `main` and halts.
- Diagnostic: `mix test` from the repo root to see which test is failing.
- Remediation: this is a safety-circuit halt. Do not continue the factory loop.
  Either revert the offending merge (`gh pr revert <n>`) or fix forward with a
  new PR.

**No JSONL file appears after `tau run` starts**
- Symptom: session exits 0 or 1 but `~/.tau/sessions/` is empty or unchanged.
- Cause: `data_dir` is misconfigured (check `tau config get data_dir`); or the
  session terminated before `open/2` was called (e.g. auth error in
  `start_session/1`).
- Diagnostic: `tau doctor` and `tau config`.

## 10. Closing M1

Once verification passes (all four success criteria in §7 are met):

1. Commit evidence artifacts as described in §8.
2. Close issue #256 with: `gh issue close 256 --comment "M1 verified. Evidence: docs/m1-verification/evidence/. Merged PR: <url>."`.
3. Close milestone `M1 — Self-hosting`: `gh api repos/smug-haus/tau/milestones --jq '.[] | select(.title | test("M1")) | .number'` to find the milestone number, then `gh api -X PATCH repos/smug-haus/tau/milestones/<n> -f state=closed`.
4. The factory loop stops being run. Per `.claude/rules/factory-loop.md` §"The sole objective": "The loop stops being run once M1 is met and verified." Do not start new factory steps.
5. Announce to any stakeholders monitoring the milestone.
