#!/usr/bin/env python3
"""Real-work evaluator adapter for tau hyperagents.

Replaces `purpose_task_eval.py` for siblings that should evolve from
real backlog work rather than synthetic probes. The adapter:

  - For role=implementer: runs the candidate scaffold against each
    task in eval_config.tasks inside a throwaway worktree of tau,
    persists a work-record per task (.claude/work-records/wr-*.json),
    and scores on immediate signals (non-empty diff/output).
  - For role=critic: picks up records where implementer is populated
    but critic is not, invokes the candidate to produce structured
    findings, appends the critic block to the record, scores by
    structural shape of the findings.
  - For role=reviewer: same shape as critic but emits a
    PASS/FAIL/PARTIAL verdict + tests block; scores by structural
    shape of the verdict.

Invocation (per hyperagents:eval-adapter-spec):

    role_eval.py --plugin-dir <scratch> --out <out_dir> --role <role> \\
                 [--stub-mode] [--max-probes N] [--run-timeout-s N]

The role is passed in settings.json args_template per sibling.
"""
import argparse
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time
from datetime import datetime, timezone
from pathlib import Path

EVALUATOR_VERSION = "tau-role-eval@1.0.0"
RUN_TIMEOUT_S = 1200
MAX_OUTPUT_CHARS = 8000
MAX_DIFF_CHARS = 200_000


def archive_root(plugin_dir: Path) -> Path:
    """``.../hyperagents/<sibling>/scratch/<id>/`` → ``.../hyperagents/<sibling>/``."""
    return plugin_dir.parent.parent


def project_root_from(plugin_dir: Path) -> Path:
    """``.../<tau>/.claude/hyperagents/<sibling>/{scratch|agents}/<id>/`` → ``.../<tau>/``."""
    return plugin_dir.parents[4]


def work_records_dir(project_root: Path) -> Path:
    d = project_root / ".claude" / "work-records"
    d.mkdir(parents=True, exist_ok=True)
    return d


def now_iso() -> str:
    return datetime.now(timezone.utc).isoformat()


def short_hash(text: str, n: int = 6) -> str:
    return hashlib.sha256(text.encode("utf-8")).hexdigest()[:n]


def make_record_id(task_body: str) -> str:
    ts = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%S")
    return f"wr-{ts}-{short_hash(task_body)}"


def load_plugin_name(plugin_dir: Path):
    pj = plugin_dir / ".claude-plugin" / "plugin.json"
    if not pj.is_file():
        return None
    try:
        return json.loads(pj.read_text(encoding="utf-8")).get("name")
    except (OSError, json.JSONDecodeError):
        return None


def parse_claude_p_json(stdout: str):
    """Parse `claude -p --output-format json` stdout → (text, tokens)."""
    try:
        obj = json.loads(stdout)
    except (json.JSONDecodeError, ValueError, TypeError):
        return (stdout, 0)
    if not isinstance(obj, dict):
        return (stdout, 0)
    text = obj.get("result", "") or ""
    u = obj.get("usage") or {}
    try:
        tokens = int(u.get("input_tokens", 0) or 0) + int(u.get("output_tokens", 0) or 0)
    except (TypeError, ValueError):
        tokens = 0
    return (str(text), tokens)


def claude_p(*, plugin_dir, input_text, cwd=None, timeout_s=RUN_TIMEOUT_S):
    """Invoke `claude -p --plugin-dir <plugin_dir>` headless.

    Returns (text, tokens, returncode, stderr_excerpt).
    """
    cmd = [
        "claude", "-p",
        "--output-format", "json",
        "--plugin-dir", str(plugin_dir),
        "--dangerously-skip-permissions",
    ]
    try:
        r = subprocess.run(
            cmd, input=input_text, cwd=cwd,
            capture_output=True, text=True, timeout=timeout_s,
        )
    except subprocess.TimeoutExpired as e:
        out = e.stdout if isinstance(e.stdout, str) else (e.stdout or b"").decode("utf-8", "replace")
        return (out or "", 0, -1, "timeout")
    text, tokens = parse_claude_p_json(r.stdout or "")
    return (text, tokens, r.returncode, (r.stderr or "")[:2000])


# ───────── worktree (only used for implementer) ─────────

class Workspace:
    """Throwaway working copy of the host repo for the implementer run."""
    def __init__(self, repo: Path):
        self.repo = Path(repo) if repo else None
        self.base = None
        self.wt = None
        self._is_worktree = False

    def __enter__(self):
        self.base = Path(tempfile.mkdtemp(prefix="tau-real-eval-"))
        self.wt = self.base / "wt"
        if self.repo and (self.repo / ".git").exists():
            subprocess.run(["git", "-C", str(self.repo), "worktree", "prune"],
                           capture_output=True, text=True)
            r = subprocess.run(
                ["git", "-C", str(self.repo), "worktree", "add", "--detach",
                 str(self.wt), "HEAD"],
                capture_output=True, text=True,
            )
            if r.returncode == 0:
                self._is_worktree = True
        if not self._is_worktree and self.repo and self.repo.is_dir():
            shutil.copytree(
                str(self.repo), str(self.wt),
                ignore=shutil.ignore_patterns(
                    ".git", "_build", "deps", "node_modules", ".venv", "priv/plts"),
                dirs_exist_ok=True,
            )
        return self.wt

    def diff(self) -> tuple[str, list[str]]:
        if not (self.wt / ".git").exists():
            return ("", [])
        subprocess.run(["git", "-C", str(self.wt), "add", "-A"],
                       capture_output=True, text=True)
        d = subprocess.run(["git", "-C", str(self.wt), "diff", "--cached"],
                           capture_output=True, text=True).stdout or ""
        names = subprocess.run(["git", "-C", str(self.wt), "diff", "--cached", "--name-only"],
                               capture_output=True, text=True).stdout or ""
        files = [ln.strip() for ln in names.splitlines() if ln.strip()]
        return (d, files)

    def __exit__(self, *exc):
        if self._is_worktree and self.repo is not None:
            subprocess.run(
                ["git", "-C", str(self.repo), "worktree", "remove", "--force", str(self.wt)],
                capture_output=True, text=True,
            )
        if self.base:
            shutil.rmtree(self.base, ignore_errors=True)


# ───────── structured-output extraction ─────────

JSON_FENCE_RE = re.compile(r"```json\s*(\{.*?\})\s*```", re.DOTALL)


def extract_json_block(text: str):
    """Best-effort: pull a JSON object out of candidate stdout."""
    if not text:
        return None
    m = JSON_FENCE_RE.search(text)
    if m:
        try:
            return json.loads(m.group(1))
        except json.JSONDecodeError:
            pass
    try:
        return json.loads(text)
    except (json.JSONDecodeError, ValueError):
        return None


# ───────── prompts ─────────

def build_critic_prompt(task: str, diff: str, stdout: str, plugin_name) -> str:
    routing = f"@{plugin_name}:task-agent\n\n" if plugin_name else ""
    return f"""{routing}You are reviewing a diff produced by another agent.

TASK:
{task}

DIFF (capped):
{diff}

IMPLEMENTER STDOUT EXCERPT:
{stdout}

Produce a critic review. Output ONLY a single ```json``` fence with this shape:

```json
{{
  "findings": [
    {{"id":"f-1","severity":"BLOCKING|SUGGESTION","category":"...","file":"...","line":0,"message":"...","evidence":"..."}}
  ],
  "single_most_important_id": "f-N or null"
}}
```

Fields `file`, `line`, `category`, `evidence` are optional but preferred.
BLOCKING = must address before merge. SUGGESTION = nice-to-have.
Empty findings list is a valid response when the diff is clean."""


def build_reviewer_prompt(task: str, diff: str, stdout: str, plugin_name) -> str:
    routing = f"@{plugin_name}:task-agent\n\n" if plugin_name else ""
    return f"""{routing}You are reviewing a diff produced by another agent.

TASK:
{task}

DIFF (capped):
{diff}

IMPLEMENTER STDOUT EXCERPT:
{stdout}

Run the toolchain checks (`mix test`, `mix format --check-formatted`,
`mix credo --strict`) if applicable. Then output ONLY a single ```json```
fence with this shape:

```json
{{
  "verdict": "PASS|FAIL|PARTIAL",
  "tests": {{"tool":"mix test","passed":0,"failed":0,"errors":0}},
  "findings": [
    {{"id":"f-1","severity":"BLOCKING|WARNING","file":"...","line":0,"message":"..."}}
  ]
}}
```

PASS = all gates clean and no silent failures. FAIL = any blocking gate
failed. PARTIAL = mixed."""


# ───────── role bodies ─────────

def run_implementer(args, eval_config, plugin_dir, out_dir, work_dir):
    tasks = eval_config.get("tasks") or []
    repo = Path(eval_config["repo"]).resolve() if eval_config.get("repo") else None
    plugin_name = load_plugin_name(plugin_dir)

    per_task = []
    total_tokens = 0
    t0 = time.monotonic()

    for task_body in tasks:
        rid = make_record_id(task_body)
        record = {
            "version": 1,
            "record_id": rid,
            "created_at": now_iso(),
            "task": {"kind": "hyperagents-task",
                     "source": "eval_config",
                     "body": task_body},
            "implementer": None,
            "critic": None,
            "reviewer": None,
            "human_action": None,
        }

        if args.stub_mode:
            passed = bool(task_body.strip())
            record["implementer"] = {
                "gen_id": plugin_name or str(plugin_dir),
                "diff": "", "files_changed": [],
                "stdout_excerpt": "stub-mode",
                "wall_clock_s": 0.0, "tokens": 0,
                "completed_at": now_iso(),
            }
            per_task.append({"task": task_body[:160], "passed": passed,
                             "why": "stub-mode" if passed else "empty-task"})
        else:
            with Workspace(repo) as wt:
                prompt = (f"@{plugin_name}:task-agent\n\n" if plugin_name else "") + task_body
                ts = time.monotonic()
                stdout_txt, tokens, rc, stderr = claude_p(
                    plugin_dir=plugin_dir, input_text=prompt, cwd=str(wt),
                    timeout_s=args.run_timeout_s,
                )
                wall = time.monotonic() - ts
                total_tokens += tokens
                diff_txt = ""
                files = []
                if (wt / ".git").exists():
                    subprocess.run(["git", "-C", str(wt), "add", "-A"],
                                   capture_output=True, text=True)
                    diff_txt = subprocess.run(["git", "-C", str(wt), "diff", "--cached"],
                                              capture_output=True, text=True).stdout or ""
                    names = subprocess.run(
                        ["git", "-C", str(wt), "diff", "--cached", "--name-only"],
                        capture_output=True, text=True).stdout or ""
                    files = [ln.strip() for ln in names.splitlines() if ln.strip()]

                passed = (rc == 0) and (bool(diff_txt.strip()) or bool(stdout_txt.strip()))
                why = "ok" if passed else (
                    f"rc={rc}; {stderr[:200]}" if rc != 0 else "no output and no diff")
                record["implementer"] = {
                    "gen_id": plugin_name or str(plugin_dir),
                    "diff": diff_txt[:MAX_DIFF_CHARS],
                    "files_changed": files[:200],
                    "stdout_excerpt": stdout_txt[:MAX_OUTPUT_CHARS],
                    "wall_clock_s": round(wall, 2),
                    "tokens": tokens,
                    "completed_at": now_iso(),
                }
                per_task.append({"task": task_body[:160], "passed": passed, "why": why})

        (work_dir / f"{rid}.json").write_text(
            json.dumps(record, indent=2) + "\n", encoding="utf-8")

    primary = (sum(1 for p in per_task if p["passed"]) / len(per_task)) if per_task else 0.0
    write_scores(out_dir, "implementer", primary, per_task,
                 wall_s=time.monotonic() - t0, tokens=total_tokens,
                 notes=f"implementer real-eval: {sum(1 for p in per_task if p['passed'])}/{len(per_task)} produced output+diff")
    return 0


def _process_pending(args, plugin_dir, work_dir, role: str, build_prompt, parse_response, max_diff=60_000, max_out=6_000):
    """Common loop for critic/reviewer: pick pending records, invoke candidate, append role block, score."""
    plugin_name = load_plugin_name(plugin_dir)
    pending = []
    for f in sorted(work_dir.glob("wr-*.json")):
        try:
            r = json.loads(f.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError):
            continue
        if r.get("implementer") and not r.get(role):
            pending.append((f, r))

    per_task = []
    total_tokens = 0
    t0 = time.monotonic()

    if not pending:
        return per_task, total_tokens, time.monotonic() - t0, "no pending records to process"

    for f, record in pending[: args.max_probes]:
        impl = record["implementer"]
        diff = (impl.get("diff") or "")[:max_diff]
        stdout = (impl.get("stdout_excerpt") or "")[:max_out]
        task = record["task"]["body"]

        if args.stub_mode:
            block, passed, why = parse_response(None, args.stub_mode, plugin_name, plugin_dir)
        else:
            prompt = build_prompt(task, diff, stdout, plugin_name)
            ts = time.monotonic()
            stdout_txt, tokens, rc, stderr = claude_p(
                plugin_dir=plugin_dir, input_text=prompt, cwd=None,
                timeout_s=args.run_timeout_s,
            )
            wall = time.monotonic() - ts
            total_tokens += tokens
            parsed = extract_json_block(stdout_txt)
            block, passed, why = parse_response(parsed, args.stub_mode, plugin_name, plugin_dir,
                                                 rc=rc, stderr=stderr,
                                                 wall_s=wall, tokens=tokens,
                                                 raw=stdout_txt)
        record[role] = block
        f.write_text(json.dumps(record, indent=2) + "\n", encoding="utf-8")
        per_task.append({"task": task[:160], "passed": passed, "why": why})

    return per_task, total_tokens, time.monotonic() - t0, None


def _critic_parse(parsed, stub, plugin_name, plugin_dir, rc=0, stderr="", wall_s=0.0, tokens=0, raw=""):
    if stub:
        block = {
            "gen_id": plugin_name or str(plugin_dir),
            "findings": [{"id": "f-1", "severity": "SUGGESTION", "message": "stub finding"}],
            "single_most_important_id": "f-1",
            "wall_clock_s": 0.0, "tokens": 0, "completed_at": now_iso(),
        }
        return block, True, "stub-mode"
    findings = []
    smi = None
    shape_ok = isinstance(parsed, dict) and isinstance(parsed.get("findings"), list)
    if shape_ok:
        for j, x in enumerate((parsed.get("findings") or [])[:50]):
            if not isinstance(x, dict):
                continue
            findings.append({
                "id": x.get("id") or f"f-{j+1}",
                "severity": x.get("severity") or "SUGGESTION",
                "category": x.get("category"),
                "file": x.get("file"),
                "line": x.get("line"),
                "message": x.get("message", ""),
                "evidence": x.get("evidence"),
            })
        smi = parsed.get("single_most_important_id")
    passed = shape_ok and rc == 0
    why = "ok" if passed else ("malformed/missing findings" if rc == 0 else f"rc={rc}; {stderr[:200]}")
    block = {
        "gen_id": plugin_name or str(plugin_dir),
        "findings": findings,
        "single_most_important_id": smi,
        "wall_clock_s": round(wall_s, 2),
        "tokens": tokens,
        "completed_at": now_iso(),
        "raw_excerpt": raw[:2000] if not passed else None,
    }
    return block, passed, why


def _reviewer_parse(parsed, stub, plugin_name, plugin_dir, rc=0, stderr="", wall_s=0.0, tokens=0, raw=""):
    if stub:
        block = {
            "gen_id": plugin_name or str(plugin_dir),
            "verdict": "PASS", "tests": None,
            "format_clean": None, "credo_clean": None,
            "findings": [],
            "wall_clock_s": 0.0, "tokens": 0, "completed_at": now_iso(),
        }
        return block, True, "stub-mode"
    verdict = None
    tests = None
    findings = []
    shape_ok = False
    if isinstance(parsed, dict):
        v = (parsed.get("verdict") or "").upper()
        if v in {"PASS", "FAIL", "PARTIAL"}:
            verdict = v
            shape_ok = True
        if isinstance(parsed.get("tests"), dict):
            tests = parsed["tests"]
        if isinstance(parsed.get("findings"), list):
            for j, x in enumerate(parsed["findings"][:50]):
                if isinstance(x, dict):
                    findings.append({
                        "id": x.get("id") or f"f-{j+1}",
                        "severity": x.get("severity") or "WARNING",
                        "file": x.get("file"),
                        "line": x.get("line"),
                        "message": x.get("message", ""),
                    })
    passed = shape_ok and rc == 0
    why = "ok" if passed else ("missing/invalid verdict" if rc == 0 else f"rc={rc}; {stderr[:200]}")
    block = {
        "gen_id": plugin_name or str(plugin_dir),
        "verdict": verdict, "tests": tests,
        "format_clean": None, "credo_clean": None,
        "findings": findings,
        "wall_clock_s": round(wall_s, 2),
        "tokens": tokens,
        "completed_at": now_iso(),
        "raw_excerpt": raw[:2000] if not passed else None,
    }
    return block, passed, why


def run_critic(args, eval_config, plugin_dir, out_dir, work_dir):
    per_task, tokens, wall, empty_reason = _process_pending(
        args, plugin_dir, work_dir, "critic",
        build_critic_prompt, _critic_parse,
    )
    if empty_reason:
        write_scores(out_dir, "critic", 0.0, per_task, wall_s=wall, tokens=tokens,
                     notes=f"critic: {empty_reason}")
        return 0
    primary = (sum(1 for p in per_task if p["passed"]) / len(per_task)) if per_task else 0.0
    write_scores(out_dir, "critic", primary, per_task, wall_s=wall, tokens=tokens,
                 notes=f"critic real-eval: {sum(1 for p in per_task if p['passed'])}/{len(per_task)} produced structured findings")
    return 0


def run_reviewer(args, eval_config, plugin_dir, out_dir, work_dir):
    per_task, tokens, wall, empty_reason = _process_pending(
        args, plugin_dir, work_dir, "reviewer",
        build_reviewer_prompt, _reviewer_parse,
    )
    if empty_reason:
        write_scores(out_dir, "reviewer", 0.0, per_task, wall_s=wall, tokens=tokens,
                     notes=f"reviewer: {empty_reason}")
        return 0
    primary = (sum(1 for p in per_task if p["passed"]) / len(per_task)) if per_task else 0.0
    write_scores(out_dir, "reviewer", primary, per_task, wall_s=wall, tokens=tokens,
                 notes=f"reviewer real-eval: {sum(1 for p in per_task if p['passed'])}/{len(per_task)} produced structured verdict")
    return 0


# ───────── scoring ─────────

def write_scores(out_dir, role, primary, per_task, *, wall_s, tokens, notes):
    out_dir = Path(out_dir); out_dir.mkdir(parents=True, exist_ok=True)
    scores = {
        "version": 1,
        "primary": float(primary),
        "metrics": {
            "pass_rate": float(primary),
            "tokens": int(tokens),
            "task_verdicts": [
                {"task": p["task"], "passed": bool(p["passed"]), "why": p.get("why", "")}
                for p in per_task
            ],
            "role": role,
        },
        "n_examples": len(per_task),
        "evaluator_version": EVALUATOR_VERSION,
        "wall_clock_s": round(wall_s, 3),
        "notes": notes,
    }
    (out_dir / "scores.json").write_text(
        json.dumps(scores, indent=2) + "\n", encoding="utf-8")


# ───────── entry point ─────────

def main():
    p = argparse.ArgumentParser()
    p.add_argument("--plugin-dir", required=True)
    p.add_argument("--out", required=True)
    p.add_argument("--role", required=True,
                   choices=["implementer", "critic", "reviewer"])
    p.add_argument("--project-root", default=None)
    p.add_argument("--stub-mode", action="store_true")
    p.add_argument("--max-probes", type=int, default=3)
    p.add_argument("--run-timeout-s", type=int, default=RUN_TIMEOUT_S)
    args = p.parse_args()

    plugin_dir = Path(args.plugin_dir).resolve()
    out_dir = Path(args.out).resolve()
    out_dir.mkdir(parents=True, exist_ok=True)

    project_root = Path(args.project_root).resolve() if args.project_root \
        else project_root_from(plugin_dir)
    work_dir = work_records_dir(project_root)

    cfg_path = archive_root(plugin_dir) / "eval_config.json"
    eval_config = {}
    if cfg_path.is_file():
        try:
            eval_config = json.loads(cfg_path.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError):
            pass

    if args.role == "implementer":
        return run_implementer(args, eval_config, plugin_dir, out_dir, work_dir)
    if args.role == "critic":
        return run_critic(args, eval_config, plugin_dir, out_dir, work_dir)
    if args.role == "reviewer":
        return run_reviewer(args, eval_config, plugin_dir, out_dir, work_dir)
    return 2


if __name__ == "__main__":
    sys.exit(main())
