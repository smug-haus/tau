---
name: code-review-patterns
description: >
  Code review checklist and anti-patterns. Use when reviewing completed
  implementations for silent failures, incomplete work, hardcoded values,
  missing error handling, or spec deviations.
---

# Code Review Patterns

Use this skill when evaluating a completed implementation. Work through each section in order. Record findings as: **pass**, **fail (evidence)**, or **N/A**.

---

## 1. Test Verification — run, don't trust

- Run the full test suite. Record exact counts: total / passing / failing.
- Check for tests that always pass regardless of implementation:
  - `assert True` or equivalent no-op assertions
  - Empty test bodies
  - Tests that never call the function under test
- Check for tests that verify implementation details rather than behavior:
  - Asserting internal variable names, call counts on private methods
  - These break on valid refactors and give false confidence

**Pass criterion**: All tests run, counts are recorded, no trivially-passing tests found.

---

## 2. Silent Failure Detection

Code that fails without signaling failure is the most dangerous class of defect.

- **Empty catch/except blocks**: Exception caught and discarded. Find with: `except:` or `except Exception:` with no body beyond `pass`.
- **Hardcoded defaults masking computation**: Function always returns the same value regardless of input. Inspect return sites.
- **Error handlers that swallow errors**: Handler logs nothing, returns nothing meaningful, caller has no way to know failure occurred.
- **Try/catch wrapping entire function bodies**: Broad catch at the outermost scope converts all failures to silent defaults.

**Pass criterion**: Every error path either propagates the error or logs it explicitly.

---

## 3. Completeness Check

- Search for `TODO`, `FIXME`, `HACK`, `XXX` comments. Each is a deferred obligation.
- Identify stub functions: function defined, body is `pass`, `raise NotImplementedError`, or a single hardcoded return.
- Map each spec requirement to the implementation:
  - Fully implemented
  - Partially implemented (note which parts are missing)
  - Not implemented
- Check edge cases explicitly mentioned in the spec.

**Pass criterion**: No stubs, no deferred items, all spec requirements accounted for.

---

## 4. Hardcoded Value Scan

- **File paths**: Absolute paths, relative paths with assumed working directory
- **URLs and ports**: Localhost assumptions, hardcoded port numbers, hardcoded endpoints
- **Credentials or keys**: Any string that looks like a token, password, or API key
- **Magic numbers**: Numeric literals without named constants or comments explaining their origin
- **Environment-specific values**: Anything that would break in a different environment (dev vs prod, different OS)

**Pass criterion**: All configuration values are parameterized or sourced from environment/config.

---

## 5. Spec Compliance

For each requirement in the spec, record: **met** / **unmet** / **partial** with evidence.

Additionally flag:
- **Gold plating**: Features or behaviors added beyond the spec. These are not automatically bad, but they are unreviewed scope and should be called out.
- **Behavioral deviations**: Implementation does something different from what the spec requires, even if it passes tests.

**Pass criterion**: All requirements are met with evidence. Deviations and additions are explicitly documented.

---

## 6. Common Anti-Patterns

- **Over-engineering**: Classes created for one-time operations, abstractions with only one implementation, premature generalization
- **Copy-paste code**: Identical or near-identical logic blocks that should be extracted (threshold: 3+ copies)
- **Inconsistent error handling**: Some call sites handle errors, others silently ignore the same failure mode
- **Missing cleanup**: Files opened but not closed, connections acquired but not released, locks acquired but not released

**Pass criterion**: No instances of the above, or each instance has a documented justification.

---

## Reference

For detailed anti-pattern examples with code snippets showing the problem and fix:

→ Read `reference/anti-patterns.md`
