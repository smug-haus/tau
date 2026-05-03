# Property Test Pattern Guide

How to translate PSDHs into executable property-based tests.

## Prerequisites

- A PSDH catalog with contracts (see `enforcement-guide.md` for which PSDHs to operationalise)
- A property-based testing library: **Hypothesis** (Python), fast-check (TypeScript/JavaScript), QuickCheck (Haskell), or equivalent
- Familiarity with the component's state transitions and public interface

This guide uses Hypothesis (Python) for all code examples. The patterns apply to any PBT library — see the portability notes at the end.

---

## Core Idea

A PSDH states a constraint in plain language. A property test checks that constraint by:

1. Generating random scenarios (input sequences, state configurations)
2. Executing those scenarios against a model or implementation
3. Asserting that the PSDH's invariant holds in every scenario

The power of PBT over example-based testing: you describe *what must always be true*, and the library finds counterexamples you didn't think of.

---

## The Two Patterns

### Pattern 1: Model-Stub

**Write a minimal model of the component's state machine. Test properties against the model.**

The model is not the implementation — it is a stripped-down simulation of the coordination semantics. It models state transitions, actor interactions, and invariants without any infrastructure, persistence, or performance concerns.

**When to use:** During design, before implementation exists. The model captures the architecture description's coordination semantics and tests that the design's invariants hold under random event sequences.

**Why a model, not a mock?** Mocks simulate interfaces. Models simulate *behaviour*. A mock of a task queue returns canned responses. A model of a task queue tracks job state, enforces visibility timeouts, and moves jobs through their lifecycle. The model is the thing you're testing.

**Structure:**

```python
# 1. The model: a minimal state machine
class TaskQueue:
    def __init__(self):
        self.jobs = {}
        self.ready_queue = []
        self.dlq = []
        self.current_time = 0.0

    def submit(self, job): ...
    def pull(self, worker_id): ...
    def ack_success(self, job_id, worker_id): ...
    def ack_failure(self, job_id, worker_id): ...
    def reclaim_expired(self): ...
    def dlq_retry(self, job_id): ...

# 2. The property test: generate random scenarios, check invariant
@given(...)
def test_psdh_some_invariant(...):
    q = TaskQueue()
    # ... exercise the model ...
    assert invariant_holds
```

The model from the research prototype (`task_queue_model.py`) demonstrates this pattern. It is a ~190-line Python class that models a distributed task queue with:

- Job state enumeration: `READY`, `PROCESSING`, `COMPLETED`, `DEAD_LETTER`, `ARCHIVED`
- State transitions: `submit`, `pull`, `ack_success`, `ack_failure`, `reclaim_expired`, `dlq_retry`, `dlq_archive`
- A simulated clock (`current_time`, `advance_time`) for testing visibility timeouts
- Ownership tracking (`worker_id`) for testing late-ack rejection

This is all the infrastructure needed to test the design's PSDHs. No network, no persistence, no threads.

### Pattern 2: Violation-Test

**Deliberately break the PSDH in the model. Confirm the test catches the violation.**

A violation test is the complement of a correctness test. It validates that your property test is actually checking something — that it would fail if the invariant were violated.

**When to use:** After writing a correctness test. The violation test confirms the test has teeth.

**Structure:**

```python
# 1. A broken model: subclass with specific violation injected
class TaskQueueBroken(TaskQueue):
    def __init__(self, violations: set):
        super().__init__()
        self.violations = violations

    def dlq_retry(self, job_id):
        # ... normal logic ...
        if "dlq_no_reset" in self.violations:
            pass  # BUG: don't reset attempt counter
        else:
            job.attempt = 0
        # ...

# 2. The violation test: exercise the broken model,
#    confirm the invariant is violated
def test_psdh3_violation_no_reset(...):
    q = TaskQueueBroken(violations={"dlq_no_reset"})
    # ... exercise ...
    # Assert the violation is detectable
    assert job.attempt != 0  # counter was NOT reset
```

The research prototype demonstrates this with `TaskQueueBroken` — a subclass of `TaskQueue` that accepts a set of named violations and injects specific bugs into the corresponding methods. Two violation tests are included:

- **`no_visibility`**: The `pull` method does not set the visibility timeout. Result: a reclaim happens immediately, and a second worker can pull the same job.
- **`dlq_no_reset`**: The `dlq_retry` method does not reset the attempt counter. Result: the job immediately re-enters the DLQ after one failure.

Both are *silent* failures — no error is thrown, no assertion fires in normal testing. Only a property test that specifically checks the PSDH's invariant catches them.

---

## Step-by-Step: From PSDH to Property Test

### Step 1: Start with the contract

Every PSDH that is assigned a property test should already have a contract (PRE/POST/INV). The contract is your test specification.

Example — PSDH-3 (Re-entry Must Reset Budget):

```
BOUNDARY: DLQ Monitor -> Queue (dlq_retry operation)
  PRE:  job.state == DEAD_LETTER and job_id in dlq
  POST: job.state = READY; job.attempt = 0; job in ready_queue;
        job NOT in dlq
  INV:  after retry, job has max_retries attempts available
```

The contract tells you:
- **What to set up:** A job in the DEAD_LETTER state, in the DLQ (the PRE)
- **What to exercise:** Call `dlq_retry` (the boundary operation)
- **What to assert:** `job.attempt == 0`, `job.state == READY`, job is in ready_queue and not in DLQ (the POST and INV)

### Step 2: Build or identify the model

If you don't have a design model yet, write one. The model needs to be just detailed enough to execute the state transitions your PSDH covers.

For the task queue, the model needs:
- A `Job` dataclass with `state`, `attempt`, `max_retries`, `visibility_timeout`, `worker_id`
- A `TaskQueue` class with `submit`, `pull`, `ack_failure`, `dlq_retry`
- A simulated clock for visibility timeout testing

It does *not* need:
- Thread safety, locks, or concurrency primitives
- Network communication or serialisation
- Persistence or durability
- Performance optimisation

The model from the research prototype is ~190 lines. Most design models for coordination components will be 100-300 lines.

### Step 3: Define the random scenario generator

Decide what varies across test iterations. For PSDH-3, the random elements are:

- `max_retries`: how many retries before DLQ (1-5)
- `visibility_timeout`: timeout duration (1.0-60.0 seconds)
- `job_type`: the type of job ("email", "report", etc.)

These are the parameters of the `Job` dataclass. A generator function produces random jobs:

```python
def random_job(rng, job_id=None):
    return Job(
        job_id=job_id or f"job-{rng.randint(0, 99999)}",
        job_type=rng.choice(["email", "report", "sync", "notification"]),
        payload=f"payload-{rng.randint(0, 999)}",
        max_retries=rng.randint(1, 5),
        visibility_timeout=rng.uniform(1.0, 60.0),
    )
```

With Hypothesis, the equivalent uses strategies:

```python
from hypothesis import given, strategies as st

job_strategy = st.builds(
    Job,
    job_id=st.text(min_size=1, max_size=20),
    job_type=st.sampled_from(["email", "report", "sync", "notification"]),
    payload=st.text(min_size=1, max_size=100),
    max_retries=st.integers(min_value=1, max_value=5),
    visibility_timeout=st.floats(min_value=1.0, max_value=60.0),
)
```

### Step 4: Write the correctness test

Follow the contract: set up the PRE, exercise the operation, assert the POST and INV.

```python
@given(job=job_strategy)
def test_psdh3_dlq_retry_resets_counter(job):
    """After DLQ retry, job should have full retry budget."""
    q = TaskQueue()
    q.submit(job)

    # Drive the job to DLQ (satisfy the PRE)
    for i in range(job.max_retries):
        pulled = q.pull(f"worker-{i}")
        assert pulled is not None
        q.ack_failure(pulled.job_id, f"worker-{i}")

    assert job.state == JobState.DEAD_LETTER

    # Exercise the operation
    q.dlq_retry(job.job_id)

    # Assert the POST
    assert job.attempt == 0, (
        f"After DLQ retry, attempt should be 0, got {job.attempt}"
    )
    assert job.state == JobState.READY

    # Assert the INV: job has full retry budget
    pulls_before_dlq = 0
    for i in range(job.max_retries):
        pulled = q.pull(f"retry-worker-{i}")
        if pulled is None:
            break
        pulls_before_dlq += 1
        q.ack_failure(pulled.job_id, f"retry-worker-{i}")

    assert pulls_before_dlq == job.max_retries, (
        f"After DLQ retry, expected {job.max_retries} attempts, "
        f"got {pulls_before_dlq}"
    )
```

### Step 5: Write the violation test

Inject the specific bug the PSDH guards against. Confirm the property test detects it.

```python
@given(job=job_strategy)
def test_psdh3_violation_no_reset(job):
    """VIOLATION: Without counter reset, DLQ retry is a no-op."""
    job.max_retries = 2  # small for clarity
    q = TaskQueueBroken(violations={"dlq_no_reset"})
    q.submit(job)

    # Drive to DLQ
    for i in range(job.max_retries):
        pulled = q.pull(f"worker-{i}")
        q.ack_failure(pulled.job_id, f"worker-{i}")

    assert job.state == JobState.DEAD_LETTER
    old_attempt = job.attempt

    # DLQ retry without reset
    q.dlq_retry(job.job_id)

    # The bug: counter still at max_retries
    assert job.attempt == old_attempt

    # One failure immediately re-DLQs
    pulled = q.pull("retry-worker")
    assert pulled is not None
    q.ack_failure(pulled.job_id, "retry-worker")

    assert job.state == JobState.DEAD_LETTER
```

### Step 6: Annotate the link back to the PSDH

Every property test should document which PSDH it operationalises. This maintains traceability from the catalog through to the test suite.

```python
"""
PSDH-3: "Re-entry Must Reset Budget"

Any operation that returns a terminated entity to the active pool
must reset the entity's exhaustion counter. Failure to reset creates
an immediate re-termination loop.

Contract:
  PRE:  job in DLQ, dlq_retry() called
  POST: job.attempt == 0 AND job.state == READY
  INV:  after DLQ retry, job has max_retries attempts available
"""
```

Place this annotation as the test function's docstring or as a comment block immediately above the test.

---

## Complete Worked Examples

The research prototype includes six passing property tests against the task queue model. Here is a summary of each, with the pattern it demonstrates.

### PSDH-1: Exhausted Retries Reach DLQ (Model-Stub)

**PSDH:** "A job that exhausts its retries must reach exactly one terminal state (DLQ) before any other terminal state."

**Contract:**
```
PRE:  job.attempt >= job.max_retries AND ack_failure called
POST: job.state == DEAD_LETTER AND job_id in dlq
INV:  no job exists in both ready_queue and dlq simultaneously
```

**Test strategy:** Generate a random job. Submit it. Fail it `max_retries` times. Assert state is `DEAD_LETTER`, job is in DLQ, and job is *not* in the ready queue.

**What it catches:** A bug where the retry-to-DLQ threshold is off by one (e.g., `attempt > max_retries` instead of `attempt >= max_retries`), or where the DLQ insertion is skipped.

### PSDH-2: Visibility Prevents Duplicate Pull (Model-Stub + Violation)

**PSDH:** "Visibility timeout is the sole mechanism preventing duplicate processing."

**Correctness test:** Submit one job. Worker A pulls it. Worker B tries to pull. Worker B gets `None` (no visible jobs). This confirms the visibility timeout hides the job from concurrent pulls.

**Violation test:** Use the broken model with `no_visibility`. Worker A pulls. Advance time minimally. Reclaim expired jobs. Worker B pulls — and gets the same job. This demonstrates that without visibility, at-least-once delivery degrades to unbounded-duplicate.

**What it catches:** A pull implementation that does not set `invisible_until`, or sets it to 0 / a past timestamp.

### PSDH-3: DLQ Retry Resets Counter (Model-Stub + Violation)

Covered in detail in the step-by-step section above.

### PSDH-4: Late Ack After Reclaim Rejected (Model-Stub)

**PSDH:** "When a timeout-based reclaim reassigns ownership, any subsequent action from the original owner must be rejected."

**Test strategy:** Worker A pulls a job. Advance time past the visibility timeout. Reclaim the job. Worker B pulls it. Worker A calls `ack_success`. Assert the ack returns `False`.

**What it catches:** An ack handler that checks only job state (`PROCESSING`) but not worker ownership (`worker_id == caller`). After reclaim, the job is `READY` or `PROCESSING` under a different worker — a state-only check might accept the late ack.

---

## Event-Sequence Testing

For PSDHs that describe invariants over sequences of operations (not just single operations), use Hypothesis's stateful testing module or generate random event sequences.

### Approach: Random Event Sequences

```python
@given(events=st.lists(
    st.sampled_from([
        'submit', 'pull', 'ack_success', 'ack_failure',
        'advance_time', 'reclaim_expired', 'dlq_retry'
    ]),
    min_size=2, max_size=30
))
def test_no_job_in_ready_and_dlq_simultaneously(events):
    """INV: No job exists in both ready_queue and dlq."""
    q = TaskQueue()
    q.submit(Job(job_id="test", job_type="email",
                 payload="p", max_retries=3))

    for event in events:
        if event == 'submit':
            q.submit(Job(job_id=f"extra-{len(q.jobs)}",
                         job_type="email", payload="p"))
        elif event == 'pull':
            q.pull("worker-1")
        elif event == 'ack_success':
            q.ack_success("test", "worker-1")
        elif event == 'ack_failure':
            q.ack_failure("test", "worker-1")
        elif event == 'advance_time':
            q.advance_time(100.0)
        elif event == 'reclaim_expired':
            q.reclaim_expired()
        elif event == 'dlq_retry':
            q.dlq_retry("test")

        # Check invariant after every event
        for job_id in q.dlq:
            assert job_id not in q.ready_queue, (
                f"Job {job_id} in both DLQ and ready_queue "
                f"after event '{event}'"
            )
```

This approach generates arbitrary sequences of operations and checks the invariant after every step. Hypothesis's shrinking will minimise any failing sequence to the shortest reproduction.

### Approach: Hypothesis Stateful Testing

For more complex state spaces, use `hypothesis.stateful.RuleBasedStateMachine`:

```python
from hypothesis.stateful import RuleBasedStateMachine, rule, initialize

class TaskQueueMachine(RuleBasedStateMachine):
    @initialize()
    def setup(self):
        self.q = TaskQueue()
        self.q.submit(Job(job_id="test", job_type="email",
                          payload="p", max_retries=3))

    @rule()
    def pull(self):
        self.q.pull("worker-1")

    @rule()
    def ack_success(self):
        self.q.ack_success("test", "worker-1")

    @rule()
    def ack_failure(self):
        self.q.ack_failure("test", "worker-1")

    @rule()
    def advance_time(self):
        self.q.advance_time(100.0)

    @rule()
    def reclaim(self):
        self.q.reclaim_expired()

    @rule()
    def dlq_retry(self):
        self.q.dlq_retry("test")

    def teardown(self):
        # Check invariant at the end of every sequence
        for job_id in self.q.dlq:
            assert job_id not in self.q.ready_queue

TestTaskQueueStates = TaskQueueMachine.TestCase
```

Hypothesis explores sequences of `@rule` calls, checking invariants at teardown (or inline after each rule). This is more structured than raw event-sequence generation and benefits from Hypothesis's sophisticated shrinking.

---

## Writing the Design Model

### What to Include

The model must capture:

1. **State enumeration.** All states a tracked entity can be in. Use an enum.
2. **State transitions.** Every operation that changes state. Each transition should validate its precondition and enforce its postcondition.
3. **Ownership / assignment tracking.** Which actor currently holds or is responsible for the entity.
4. **Time simulation.** If the PSDH involves timeouts or temporal ordering, the model needs a simulated clock (`current_time` + `advance_time`).
5. **Collection membership.** If the PSDH's invariant involves "entity is in collection X and not in collection Y," the model must track collection membership explicitly.

### What to Exclude

- Concurrency primitives (locks, semaphores, channels) — the model is single-threaded; concurrency is simulated by interleaving operations
- Network or I/O — the model operates on in-memory state
- Persistence or durability — the model exists for the duration of the test
- Performance concerns — the model should be correct, not fast

### Size Guideline

A design model for a coordination-heavy component is typically 100-300 lines. If it exceeds 500 lines, you are likely modelling more than necessary — strip out anything that doesn't support a PSDH property test.

### The Broken Variant

For violation tests, create a subclass that injects specific bugs. The broken variant:

- Inherits the correct model
- Accepts a set of named violations at construction
- Overrides specific methods to skip or corrupt the operation guarded by the PSDH

This keeps the broken behaviour explicit and traceable. Each violation corresponds to exactly one PSDH.

```python
class TaskQueueBroken(TaskQueue):
    def __init__(self, violations: set):
        super().__init__()
        self.violations = violations

    def dlq_retry(self, job_id):
        job = self.jobs.get(job_id)
        if not job or job.state != JobState.DEAD_LETTER:
            return False
        if job_id in self.dlq:
            self.dlq.remove(job_id)
        job.state = JobState.READY

        if "dlq_no_reset" not in self.violations:
            job.attempt = 0  # correct behaviour

        # If "dlq_no_reset" is in violations, skip the reset — BUG

        job.invisible_until = 0.0
        self.ready_queue.append(job_id)
        return True
```

---

## Portability to Other PBT Libraries

The patterns in this guide use Hypothesis (Python) for code examples. The same patterns apply to other PBT libraries with minor syntactic changes.

| Library | Language | Random Generation | Stateful Testing | Shrinking |
|---------|----------|-------------------|------------------|-----------|
| **Hypothesis** | Python | `@given` + strategies | `RuleBasedStateMachine` | Automatic |
| **fast-check** | TypeScript/JS | `fc.assert` + arbitraries | `fc.commands` (model-based) | Automatic |
| **QuickCheck** | Haskell | `forAll` + `Gen` | `Test.QuickCheck.Monadic` | Automatic |
| **proptest** | Rust | `proptest!` macro | Manual (but type system helps) | Automatic |
| **rapid** | Go | `rapid.Check` | Limited | Automatic |

Key translation points:

- **Strategy → Arbitrary/Gen:** The random data generator. All PBT libraries have equivalent combinators for building complex generators from primitives.
- **`@given` → `forAll` / `fc.assert` / `proptest!`:** The test runner that feeds random inputs to the property function.
- **`assume()` → filter/pre-condition:** Skip inputs that don't satisfy preconditions. Available in all libraries.
- **Stateful testing:** Hypothesis's `RuleBasedStateMachine` and fast-check's `fc.commands` provide the most structured support. In other libraries, generate random event sequences as lists and iterate manually.

---

## Summary Checklist

For each PSDH assigned a property test:

- [ ] Extract the contract (PRE/POST/INV) from the PSDH catalog
- [ ] Build or identify the design model
- [ ] Define the random scenario generator (strategies / arbitraries)
- [ ] Write the correctness test (model-stub pattern)
- [ ] Write the violation test (confirm the test catches the bug)
- [ ] Annotate the test with the PSDH reference
- [ ] Run against the model — all correctness tests pass, all violation tests demonstrate the bug
- [ ] When the implementation exists, adapt the test to run against the real code (replace model calls with implementation calls, keep the same properties)
