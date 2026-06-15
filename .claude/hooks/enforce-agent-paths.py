#!/usr/bin/env python3
"""
PreToolUse hook: mechanically scope what each subagent ROLE may write.

Roles are identified by the `agent_type` field that Claude Code injects into the
PreToolUse payload for Task-spawned subagents (populated from the registered
subagent name). The main thread has no `agent_type` and is never restricted here.

Enforcement (fail-closed for restricted roles):
  - implementer : may ONLY create/modify application code under lib/ or web/lib/.
                  Any Write/Edit/NotebookEdit elsewhere (tests, docs, specs,
                  MISSION.md, mix.exs, config/, .claude/, …) is DENIED.
                  A `git commit` that stages any non-(lib|web/lib) path is DENIED
                  (closes the Bash-circumvention vector — echo/sed/tee then commit).
  - test-author : may ONLY write tests under test/ or web/test/.
  - reviewer    : read-only — may not Write/Edit/NotebookEdit or commit at all.
  - critic      : read-only — same.
  - (any other role / main thread) : unrestricted (this hook is a no-op).

The implementer "does nothing but edit code" is therefore structural, not a
prompt. Stdlib only (json/sys/os/re/subprocess), per .claude/rules/hooks-and-scripts.md.

Deny mechanism: emit the documented PreToolUse JSON with
hookSpecificOutput.permissionDecision == "deny"; exit 0. Anything we allow falls
through (exit 0, no output) to the normal permission flow.
"""

import json
import os
import re
import subprocess
import sys

# role -> tuple of allowed repo-relative path prefixes (forward slashes).
# An empty tuple means "this role may not write anything".
ROLE_ALLOW = {
    "implementer": ("lib/", "web/lib/"),
    "test-author": ("test/", "web/test/"),
    "reviewer": (),
    "critic": (),
}

WRITE_TOOLS = ("Write", "Edit", "NotebookEdit", "MultiEdit")


def _deny(reason):
    print(
        json.dumps(
            {
                "hookSpecificOutput": {
                    "hookEventName": "PreToolUse",
                    "permissionDecision": "deny",
                    "permissionDecisionReason": reason,
                }
            }
        )
    )
    # Mirror to stderr for the transcript / debugging.
    sys.stderr.write("[enforce-agent-paths] DENY: " + reason + "\n")
    sys.exit(0)


def _allow():
    sys.exit(0)


def _repo_rel(file_path, cwd):
    """Best-effort repo-relative path (forward slashes). Returns None if it
    cannot be confidently determined (caller treats None as out-of-scope)."""
    if not file_path:
        return None
    fp = file_path.replace("\\", "/")
    cwd = (cwd or "").replace("\\", "/").rstrip("/")

    if not fp.startswith("/"):
        # already relative — strip a leading ./
        return re.sub(r"^\./", "", fp)

    # absolute: relativise against the agent's cwd (its worktree root)
    if cwd and (fp == cwd or fp.startswith(cwd + "/")):
        return fp[len(cwd) + 1 :] if fp != cwd else ""

    # absolute but not under cwd: try to recover the path after a worktree/repo
    # root segment (….claude/worktrees/agent-XXXX/<rel>  or  …/tau/<rel>).
    m = re.search(r"/(?:agent-[0-9a-fA-F]+|tau)/(.+)$", fp)
    if m:
        return m.group(1)
    return None  # cannot determine -> out of scope -> denied for restricted roles


def _under_allow(rel, allow):
    return rel is not None and any(rel == p.rstrip("/") or rel.startswith(p) for p in allow)


def main():
    try:
        payload = json.loads(sys.stdin.read() or "{}")
    except (ValueError, json.JSONDecodeError):
        _allow()  # never block on a parse failure of our own making

    role = payload.get("agent_type")
    if role not in ROLE_ALLOW:
        _allow()  # main thread or an unrestricted role

    tool = payload.get("tool_name")
    tinput = payload.get("tool_input") or {}
    cwd = payload.get("cwd") or os.getcwd()
    allow = ROLE_ALLOW[role]

    # --- file-write tools: check the target path ---
    if tool in WRITE_TOOLS:
        fp = tinput.get("file_path") or tinput.get("path") or tinput.get("notebook_path")
        rel = _repo_rel(fp, cwd)
        if not allow:
            _deny(
                "Role '%s' is read-only and may not %s files (target: %s)."
                % (role, tool, fp)
            )
        if not _under_allow(rel, allow):
            _deny(
                "Role '%s' may ONLY write %s. Blocked %s to '%s' (resolved '%s'). "
                "Application code only — tests/specs/docs are authored by other roles."
                % (role, list(allow), tool, fp, rel)
            )
        _allow()

    # --- Bash: block committing out-of-scope paths (circumvention guard) ---
    if tool == "Bash":
        cmd = tinput.get("command") or ""
        if re.search(r"\bgit\b[^\n]*\bcommit\b", cmd):
            try:
                res = subprocess.run(
                    ["git", "-C", cwd, "diff", "--cached", "--name-only"],
                    capture_output=True,
                    text=True,
                    timeout=4,
                )
                staged = [l.strip() for l in res.stdout.splitlines() if l.strip()]
            except Exception:
                staged = []
            bad = [f for f in staged if not _under_allow(f, allow)]
            if bad:
                _deny(
                    "Role '%s' may only commit %s; staged out-of-scope paths: %s. "
                    "Stage and commit application code only."
                    % (role, list(allow) or "nothing", bad[:8])
                )
        _allow()

    _allow()


if __name__ == "__main__":
    main()
