---
description: Rules for hook scripts and automation infrastructure
---

# Hook and Script Rules

Hook scripts are infrastructure, not task code. Apply these rules without exception.

**Never modify hook scripts during agent work.** Hooks are the enforcement layer — editing them mid-task disables monitoring and safety guarantees. Treat them as read-only unless specifically tasked with hook development.

**Hook changes require a session restart.** Claude Code loads hook registrations at session start. Changes to `.claude/settings.json` or hook script logic take effect only after restarting the session.

**Do not route around hooks.** If a hook blocks an action, treat the block as signal. Stop, read the reason, and address the underlying issue. Circumventing the kill cascade defeats its purpose.

**Hook scripts use Python stdlib only.** No pip dependencies. `json`, `hashlib`, `pathlib`, `sys`, `os`, `collections` — that is the full allowed set.
