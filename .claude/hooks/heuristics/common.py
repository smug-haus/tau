"""
common.py — Shared utilities for heuristic hooks.

Provides: path resolution, observation window loading, input hashing,
input/response summarization, files-referenced extraction, test result
parser dispatch, and full observation record construction.

Python stdlib only. No pip dependencies.
"""

import hashlib
import json
import os
from datetime import datetime, timezone
from pathlib import Path


# ---------------------------------------------------------------------------
# Path resolution
# ---------------------------------------------------------------------------

def get_project_root() -> Path:
    """Return project root from env, with fallbacks."""
    root = (
        os.environ.get("HARNESS_PROJECT_ROOT")
        or os.environ.get("CLAUDE_PROJECT_DIR")
        or "."
    )
    return Path(root)


def get_obs_path(project_root: Path = None) -> Path:
    """Return path to observations.jsonl."""
    root = project_root if project_root is not None else get_project_root()
    return root / ".claude" / "logs" / "observations.jsonl"


def get_attempt_id() -> str:
    """Return current attempt ID from env (default '1')."""
    return os.environ.get("HARNESS_ATTEMPT_ID", "1")


# ---------------------------------------------------------------------------
# Window loading
# ---------------------------------------------------------------------------

def load_window(n: int, obs_path: Path = None, attempt_id: str = None) -> list:
    """Load last N observations from observations.jsonl.

    If attempt_id is provided, only observations with a matching attempt_id
    field are included before slicing to N.

    Returns empty list if file is absent. Skips malformed lines silently.
    """
    path = obs_path if obs_path is not None else get_obs_path()
    if not path.exists():
        return []

    observations = []
    with open(path, "r") as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                observations.append(json.loads(line))
            except json.JSONDecodeError:
                continue

    if attempt_id is not None:
        observations = [o for o in observations if o.get("attempt_id") == attempt_id]

    return observations[-n:] if n > 0 else []


# ---------------------------------------------------------------------------
# Hash utility
# ---------------------------------------------------------------------------

def compute_input_hash(tool_name: str, tool_input: dict) -> str:
    """Deterministic 16-char hex hash of tool_name + normalized tool_input.

    Used by H-003 to detect repeated identical calls.
    """
    canonical = json.dumps(
        {"tool": tool_name, "input": tool_input}, sort_keys=True
    )
    return hashlib.sha256(canonical.encode()).hexdigest()[:16]


# ---------------------------------------------------------------------------
# Summarisation
# ---------------------------------------------------------------------------

def summarize_input(tool_name: str, tool_input: dict) -> str:
    """Short human-readable summary of a tool call's input."""
    if tool_name == "Bash":
        return tool_input.get("command", "")[:120]
    if tool_name in ("Edit", "Write"):
        path = tool_input.get("file_path") or tool_input.get("path", "")
        return f"file: {path}"
    if tool_name in ("Read", "Glob", "Grep"):
        path = tool_input.get("file_path") or tool_input.get("pattern") or tool_input.get("path", "")
        return str(path)[:120]
    return str(tool_input)[:120]


def summarize_response(tool_name: str, tool_response) -> str:
    """Short human-readable summary of a tool call's response."""
    if tool_response is None:
        return ""

    if isinstance(tool_response, str):
        return tool_response[:200]

    if isinstance(tool_response, dict):
        # Bash: prefer exit_code + brief stdout tail
        if tool_name == "Bash":
            exit_code = tool_response.get("exit_code")
            stdout = tool_response.get("stdout", "")
            stderr = tool_response.get("stderr", "")
            combined = (stdout + stderr).strip()
            tail = combined[-100:] if len(combined) > 100 else combined
            if exit_code is not None:
                return f"exit_code={exit_code}, {tail}"
            return tail
        # Generic dict: first 200 chars of JSON
        return json.dumps(tool_response)[:200]

    return str(tool_response)[:200]


# ---------------------------------------------------------------------------
# Files referenced
# ---------------------------------------------------------------------------

def extract_files_referenced(tool_name: str, tool_input: dict) -> list:
    """Extract file paths referenced in a tool call.

    Returns a list of strings (may be empty).
    """
    if tool_name in ("Read", "Write", "Edit"):
        path = tool_input.get("file_path") or tool_input.get("path")
        return [path] if path else []

    if tool_name == "Glob":
        path = tool_input.get("path")
        return [path] if path else []

    if tool_name == "Bash":
        # Best-effort: look for file-like tokens in the command
        cmd = tool_input.get("command", "")
        tokens = cmd.split()
        return [t for t in tokens if "/" in t and not t.startswith("-")][:5]

    return []


# ---------------------------------------------------------------------------
# Test result extraction (parser dispatch)
# ---------------------------------------------------------------------------

_TEST_INDICATORS = [
    "pytest", "npm test", "npm run test", "make test",
    "jest", "mocha", "cargo test", "go test",
    "vitest", "npx vitest",
]


def extract_test_results(tool_name: str, tool_input: dict, tool_response) -> dict | None:
    """Parse test results from a Bash tool response.

    Dispatches to parser modules when available; returns None for non-test
    calls or when no results can be parsed.

    Each parser module exposes: parse(output: str) -> dict | None
    Returned dict shape: {"pass": int, "fail": int}  (keys may vary by parser)
    """
    if tool_name != "Bash":
        return None

    cmd = tool_input.get("command", "")
    if not any(ind in cmd for ind in _TEST_INDICATORS):
        return None

    # Collect raw output
    output = _collect_output(tool_response)
    if not output:
        return None

    # Try each parser in turn; use first non-None result
    parsers = _load_parsers()
    for parser in parsers:
        try:
            result = parser.parse(output)
            if result is not None:
                return result
        except Exception:
            continue

    return None


def _collect_output(tool_response) -> str:
    """Extract combined text output from a tool response."""
    if isinstance(tool_response, str):
        return tool_response
    if isinstance(tool_response, dict):
        return tool_response.get("stdout", "") + tool_response.get("stderr", "")
    return ""


def _load_parsers() -> list:
    """Import available parser modules; skip missing ones silently."""
    parsers = []
    candidates = [
        ".parsers.pytest_parser",
        ".parsers.jest_parser",
        ".parsers.vitest_parser",
        ".parsers.go_test_parser",
    ]
    for name in candidates:
        try:
            # Relative import resolved via importlib to avoid package-level side effects
            import importlib
            mod = importlib.import_module(name, package=__name__.rsplit(".", 1)[0] if "." in __name__ else __package__)
            parsers.append(mod)
        except ImportError:
            continue
    return parsers


# ---------------------------------------------------------------------------
# D-xxx heuristic discovery
# ---------------------------------------------------------------------------

def discover_heuristics(design_dir: Path) -> list:
    """Discover and import D-xxx heuristic modules from design_dir.

    Scans design_dir for *.py files (excluding __init__.py), imports each
    with importlib, and returns modules that expose an evaluate(observation,
    window) callable.

    Returns empty list if design_dir is absent or empty.
    Logs ImportError to stderr and skips the offending module; modules
    without an evaluate function are silently skipped.
    """
    import importlib.util
    import sys

    if not design_dir or not Path(design_dir).exists():
        return []

    modules = []
    for py_file in sorted(Path(design_dir).glob("*.py")):
        if py_file.name == "__init__.py":
            continue
        module_name = f"_dxxx_heuristic_{py_file.stem}"
        try:
            spec = importlib.util.spec_from_file_location(module_name, py_file)
            mod = importlib.util.module_from_spec(spec)
            sys.modules[module_name] = mod
            spec.loader.exec_module(mod)
        except ImportError as exc:
            import sys as _sys
            print(f"discover_heuristics: skipping {py_file.name}: {exc}", file=_sys.stderr)
            continue
        if callable(getattr(mod, "evaluate", None)):
            modules.append(mod)

    return modules


# ---------------------------------------------------------------------------
# Observation record construction
# ---------------------------------------------------------------------------

def make_observation(event: dict, step: int = None) -> dict:
    """Build a structured observation record from a hook event dict.

    If step is None, it is inferred from the current observation count + 1.
    """
    tool_name = event.get("tool_name", "unknown")
    tool_input = event.get("tool_input") or {}
    tool_response = event.get("tool_response")

    if step is None:
        obs_path = get_obs_path()
        existing = load_window(10_000, obs_path)
        step = len(existing) + 1

    return {
        "session_id": event.get("session_id") or os.environ.get("CLAUDE_SESSION_ID", ""),
        "attempt_id": event.get("attempt_id") or get_attempt_id(),
        "tool_use_id": event.get("tool_use_id", ""),
        "step": step,
        "tool_name": tool_name,
        "tool_input_hash": compute_input_hash(tool_name, tool_input),
        "tool_input_summary": summarize_input(tool_name, tool_input),
        "tool_response_summary": summarize_response(tool_name, tool_response),
        "timestamp": datetime.now(timezone.utc).isoformat(),
        "files_referenced": extract_files_referenced(tool_name, tool_input),
        "test_results": extract_test_results(tool_name, tool_input, tool_response),
    }
