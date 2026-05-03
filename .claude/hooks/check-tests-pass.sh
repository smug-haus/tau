#!/usr/bin/env bash
# SubagentStop command hook: verify tests pass before allowing completion.
# Reads SubagentStop JSON from stdin; blocks (exit 2) if tests fail.

set -euo pipefail

# Read stdin JSON
input=$(cat)

# If stop_hook_active is true, skip to avoid infinite recursion
stop_hook_active=$(echo "$input" | python3 -c "
import sys, json
d = json.load(sys.stdin)
print(str(d.get('stop_hook_active', False)).lower())
" 2>/dev/null || echo "false")

if [ "$stop_hook_active" = "true" ]; then
    exit 0
fi

# Detect project stack from file presence
PROJECT_ROOT="$(pwd)"

run_tests() {
    local runner="$1"
    local cmd="$2"
    local output
    local rc

    output=$(eval "$cmd" 2>&1) || rc=$?
    rc=${rc:-0}

    # Parse results via Python parser
    summary=$(python3 - "$runner" <<EOF
import sys, importlib.util, os

runner = sys.argv[1]
parsers_dir = os.path.join(os.path.dirname(os.path.abspath("$0")), "heuristics", "parsers")
spec = importlib.util.spec_from_file_location(runner, os.path.join(parsers_dir, f"{runner}.py"))
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)

output = sys.stdin.read()
result = mod.parse(output)
failures = result.get("failures", 0)
errors = result.get("errors", 0)
passes = result.get("passes", 0)
print(f"{passes} passed, {failures} failed, {errors} errors" if "errors" in result else f"{passes} passed, {failures} failed")
EOF
<<< "$output")

    failures=$(echo "$summary" | grep -oP '\d+(?= failed)' || echo "0")
    errors=$(echo "$summary" | grep -oP '\d+(?= errors)' || echo "0")

    if [ "${failures:-0}" -gt 0 ] || [ "${errors:-0}" -gt 0 ]; then
        echo "Tests failed: $summary" >&2
        echo "$output" >&2
        exit 2
    fi
}

# Detect and run

# Elixir / Mix — checked first because Tau is an Elixir project and we want the
# cheapest fast-path. If mix.exs exists, this branch owns the run regardless of
# whether mix itself is on PATH (we pass through rather than fall through to
# other detectors).
if [ -f "$PROJECT_ROOT/mix.exs" ]; then
    if ! command -v mix &>/dev/null; then
        # Toolchain not installed; the tau-toolchain skill handles install separately.
        echo "[check-tests-pass.sh] mix not on PATH; passing through" >&2
        exit 0
    fi
    # Sandbox tolerance: `mix deps.get` cannot reach hex.pm in the Anthropic
    # sandbox, so deps/ may be empty. Pass through rather than failing closed
    # on a "Could not find Hex" error. See .claude/skills/tau-toolchain/SKILL.md.
    if [ ! -d "$PROJECT_ROOT/deps" ] || [ -z "$(ls -A "$PROJECT_ROOT/deps" 2>/dev/null)" ]; then
        echo "[check-tests-pass.sh] deps/ not populated; passing through" >&2
        exit 0
    fi
    run_tests "mix_test_parser" "MIX_ENV=test mix test --color=never 2>&1"
    exit 0
fi

if [ -f "$PROJECT_ROOT/pytest.ini" ] || [ -f "$PROJECT_ROOT/setup.cfg" ] || [ -f "$PROJECT_ROOT/pyproject.toml" ] || find "$PROJECT_ROOT" -maxdepth 2 -name "test_*.py" -o -name "*_test.py" 2>/dev/null | grep -q .; then
    if command -v pytest &>/dev/null; then
        run_tests "pytest_parser" "pytest --tb=short -q 2>&1"
        exit 0
    fi
fi

if [ -f "$PROJECT_ROOT/package.json" ]; then
    if command -v npx &>/dev/null && npx --yes jest --version &>/dev/null 2>&1; then
        run_tests "jest_parser" "npx jest --ci 2>&1"
        exit 0
    fi
fi

if [ -f "$PROJECT_ROOT/go.mod" ]; then
    if command -v go &>/dev/null; then
        run_tests "go_test_parser" "go test ./... 2>&1"
        exit 0
    fi
fi

# No test runner found — pass through
exit 0
