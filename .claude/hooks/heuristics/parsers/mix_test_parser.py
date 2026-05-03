"""Mix/ExUnit output parser — extracts pass/fail/error counts from `mix test` output."""
import re


def parse(output: str) -> dict:
    """Parse Mix/ExUnit output and return pass/failure counts.

    Returns dict with keys:
      passes   (int): tests + doctests + properties that succeeded
      failures (int): failed tests (includes ExUnit "invalid" — failed property setup or invariants)
      errors   (int): compile errors (mix prints "** (CompileError)" / similar before tests run)

    Mix summary lines look like:
        "Finished in 0.5 seconds (0.2s async, 0.3s sync)"
        "12 doctests, 8 properties, 145 tests, 2 failures, 1 invalid"
        "3 tests, 0 failures"
        "1 test, 1 failure"
    """
    # Strip ANSI colour codes — mix test colours by default when stderr is a TTY.
    clean = re.sub(r'\x1b\[[0-9;]*m', '', output)

    tests = doctests = properties = failures = invalid = excluded = skipped = errors = 0
    summary_found = False

    for line in reversed(clean.splitlines()):
        line = line.strip()
        if not line:
            continue
        # A summary line has at least one "<n> <noun>" pair where noun is a recognised counter.
        if re.search(r'\d+\s+(?:tests?|failures?|doctests?|properties|invalid|excluded|skipped|errors?)\b', line):
            for n, noun in re.findall(
                r'(\d+)\s+(doctests?|properties|tests?|failures?|invalid|excluded|skipped|errors?)',
                line,
            ):
                n = int(n)
                if noun.startswith('doctest'):
                    doctests = n
                elif noun.startswith('propert'):
                    properties = n
                elif noun.startswith('test'):
                    tests = n
                elif noun.startswith('failure'):
                    failures = n
                elif noun == 'invalid':
                    invalid = n
                elif noun == 'excluded':
                    excluded = n
                elif noun == 'skipped':
                    skipped = n
                elif noun.startswith('error'):
                    errors = n
            summary_found = True
            break

    # Compile-error fallback: when compilation fails ExUnit never prints a
    # summary (tests don't run). Detect "** (SomeError)" only in that case so
    # we don't misclassify runtime errors inside per-failure detail blocks.
    if not summary_found:
        if re.search(r'\*\*\s+\([A-Za-z]+Error\)', clean):
            errors = max(errors, 1)
        # Last-resort: count enumerated failure blocks "  1) test name (Module)".
        failures = len(re.findall(r'^\s+\d+\)\s', clean, re.MULTILINE))

    passes = max(0, tests + doctests + properties - failures - invalid - excluded - skipped)

    return {"passes": passes, "failures": failures + invalid, "errors": errors}
