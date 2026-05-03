# Elicitation Prompt Template

This document provides a copy-pasteable system prompt for LLM-assisted L0 elicitation sessions. The prompt frames the LLM as a structured interviewer that applies the [L0 protocol](l0-protocol.md) to a component's architecture description and records the constraints discovered.

The approach adapts the Self-Spec/FMInterviewer pattern (validated at function level by OpenReview 2025) to architecture-level constraint discovery. The key adaptation: instead of generating formal specifications from code, the LLM asks structured questions about design descriptions and records plain-language constraints.

---

## System Prompt

Copy the following prompt into your LLM session (system prompt, CLAUDE.md, or conversation preamble). Replace `[COMPONENT DESCRIPTION]` with the architecture description of the component under analysis.

```
You are a design constraint analyst. Your role is to systematically
discover implicit constraints, assumptions, and coordination gaps in
software component designs using the L0 structured questioning protocol.

## Your Task

Apply the 8 L0 questions below to the component description provided.
For each question:

1. Ask the question about the specific component. Reference concrete
   actors, state, and boundaries from the description — not abstractions.
2. Record every constraint you discover. A constraint is an implicit
   assumption, an unspecified behaviour, a potential race condition,
   an information-loss boundary, or any property that must hold for
   correctness but is not explicitly stated in the description.
3. For each constraint, note:
   - What the constraint is (plain language, one sentence)
   - Which actors or state are involved
   - What happens if the constraint is violated
   - Whether the constraint is non-obvious (not visible from a
     normal-speed reading of the description)

## The 8 L0 Questions

Apply these in order. Do not skip questions — even if a question seems
inapplicable, state that explicitly ("Q3: No silent failure modes
identified because...").

Q1. SHARED MUTABLE STATE: What can be written by more than one actor?

Q2. TEMPORAL COUPLING: What ordering assumptions are implicit?

Q3. PARTIAL FAILURE: What happens if a component fails silently?

Q4. INTERFACE FIDELITY: What information crosses a boundary, and what
    is lost in transit?

Q5. FEEDBACK STABILITY: What feedback loops exist, and can they diverge?

Q6. PHASE INVARIANTS: What must be true before and after each phase
    transition?

Q7. PROTOCOL ORDERING: What is the communication protocol between
    components, and what happens if a message arrives out of order?

Q8. CHANGE PROPAGATION: If you change component X, what properties of
    connected components Y and Z must be re-verified?

## Output Format

For each question, produce output in this structure:

### Q[N]: [Question Name]

[Analysis: 2-5 sentences applying the question to the component]

**Constraints found:**

- **[ID]:** [One-sentence constraint statement]
  - Actors/state: [what is involved]
  - Violation consequence: [what breaks]
  - Non-obvious: [Yes/No/Semi — with brief justification]

If no constraints are found for a question, state: "No constraints
found. [Brief explanation of why this question does not apply.]"

## After All 8 Questions

Provide a summary:

1. Total constraints found
2. Count of non-obvious constraints
3. Top 3 highest-risk constraints (those with the most severe
   violation consequences)
4. Escalation recommendation: should this component proceed to L1
   state enumeration? (Yes if the component has 3+ coordination
   properties and L0 surfaced timing-dependent constraints.)

## Important Guidelines

- Be concrete. "There might be issues with state" is not a constraint.
  "The job state record can be modified by both the worker (ack) and
  the queue (visibility reclaim) without a serialization mechanism"
  is a constraint.
- Be honest about uncertainty. If a constraint depends on implementation
  details not in the description, say so: "This constraint is
  conditional on [X]. If [X] is handled by [mechanism], it may not
  apply."
- Do not invent mechanisms. If the description does not mention locking,
  do not assume locking exists. Constraints arise from what is *absent*
  in the description, not from what you imagine might be present.
- Do not over-generate. Quality over quantity. 5 well-specified
  constraints are more valuable than 15 vague ones. If a question
  produces nothing non-obvious, say so and move on.
- Use the component's own vocabulary. If the description calls it a
  "worker," call it a "worker" — not a "consumer" or "processor"
  unless the description uses those terms.
```

---

## Usage

### Starting a session

1. Set up the system prompt above (or paste it at the start of the conversation).
2. Provide the component description as a user message:

```
Here is the component to analyze:

[Paste the architecture description, design document, or natural-language
specification of the component.]
```

3. The LLM will apply all 8 questions and produce structured output.

### Following up

After the initial analysis, common follow-up prompts:

- **"Expand on constraint [ID]."** — Ask for more detail on a specific constraint, including potential mitigation approaches.
- **"Which of these constraints would be caught by standard unit tests?"** — Helps distinguish constraints that need explicit PSDH treatment from those already covered by normal testing.
- **"Express constraints [ID], [ID], and [ID] as pre/post/invariant contracts for the [X ↔ Y] boundary."** — Transitions from L0 discovery to contract expression (Layer 2 of the method).
- **"Proceed to L1 state enumeration for the [specific interaction] identified in Q[N]."** — Escalates to L1 for a targeted area.

### Adapting for different contexts

**For a design review meeting (human-led, LLM-assisted):**
Remove the output format specification and instead instruct the LLM to ask the questions interactively, one at a time, waiting for the human to respond before proceeding. This turns the LLM into a facilitator rather than an analyst.

Add to the system prompt:
```
Instead of analyzing the component yourself, act as an interviewer.
Ask each question one at a time and wait for the human architect to
respond. After each response, identify any constraints mentioned and
ask clarifying follow-ups before moving to the next question. Record
all constraints in the format specified above.
```

**For a codebase rather than a design document:**
If no architecture description exists, the LLM can work from code, but the prompt needs adjustment.

Add to the system prompt:
```
The input is source code rather than a design document. Before applying
the L0 questions, first summarize the component's architecture in 5-10
sentences: what are the actors, what state do they share, what are the
boundaries between them. Then apply the L0 questions to your own summary.
Flag any constraints that may be artifacts of your summarization rather
than genuine design gaps.
```

**For a flywheel iteration (second pass):**
When feeding PSDHs back into the L0 protocol for a second discovery cycle.

Add to the system prompt:
```
This is a second-pass analysis. The following PSDHs were extracted from
the first pass:

[Paste PSDHs here]

Re-run Q1-Q8 with these PSDHs as additional context. For each question,
ask: given that we know these constraints, what additional constraints
does this question surface? Focus on interactions between PSDHs and
between PSDHs and the original component description.
```

---

## Escalation Triggers

During the L0 session, escalate to L1 state enumeration if any of these conditions are observed:

| Trigger | What to do |
|---------|------------|
| Three or more constraints involve timing or concurrent access to the same resource | Escalate the specific resource interaction to L1. List all actors that touch the resource and enumerate their states. |
| A constraint identifies a "race" or "state fork" (two actors can produce conflicting outcomes simultaneously) | Escalate the specific race to L1. Enumerate the state combinations that produce the conflict and check which ones are prevented by existing mechanisms. |
| The summary shows >= 8 raw constraints with >= 5 non-obvious | The component is highly coordination-heavy. Full L1 is warranted for its top 2-3 interactions. |
| A constraint depends on "what if X happens while Y is in progress" | Temporal overlap constraint. L1's actor-state matrix will reveal whether the overlap is possible and what the consequences are. |

---

## Output Specification

The elicitation session should produce a structured artifact suitable for the next step of the method (contract expression). The minimum useful output is:

```
# L0 Elicitation Results: [Component Name]

## Triage Score: [N/5]
[Which properties are present]

## Constraints

### From Q1 (Shared Mutable State)
- C1: [constraint]
- C2: [constraint]

### From Q2 (Temporal Coupling)
[...]

[...through Q8...]

## Summary
- Total constraints: [N]
- Non-obvious: [N]
- Top risks:
  1. [highest risk constraint and why]
  2. [second highest]
  3. [third highest]

## Escalation
- L1 recommended: [Yes/No]
- If yes, for which interactions: [list]

## Next Steps
- Proceed to contract expression for boundaries: [list boundaries]
- Constraints requiring human validation: [list any conditional ones]
```

---

## LLM Competence Notes

Based on research validation (Phase 1b-1):

**What the LLM does well at L0:**
- Systematic application of the protocol (does not skip steps or get bored)
- Identifying structural gaps — places where the description says "X happens" but does not say "and then Y is cleaned up"
- Appropriate hedging on uncertain claims
- Pattern matching against known failure modes (concurrent writes, stale state, off-by-one errors)

**What the LLM does less well:**
- Cannot validate "plausible" constraints without access to the running system
- May miss domain-specific subtleties that a human expert with deep system knowledge would catch
- Tends to generate more constraints rather than better ones — review for quality, not just quantity
- Self-assessment of constraint validity is unreliable — human review of the output is a necessary step

**Error profile observed in research:**
- 0 of 13 constraints were confidently wrong (no hallucinated mechanisms or reversed causality)
- 8 of 13 were confidently correct (structural observations following directly from the description)
- 5 of 13 were plausible but conditional on implementation details not in the description

The LLM is a generation and iteration partner, not a verification oracle. Every constraint it produces should be reviewed by someone with knowledge of the actual system before being promoted to a PSDH.
