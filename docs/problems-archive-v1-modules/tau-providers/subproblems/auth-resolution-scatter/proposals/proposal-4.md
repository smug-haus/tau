---
template_version: 1
template_name: proposal
proposal_id: 4
parent_problem: ../problem.md
---

# Proposal 4: Document-only per-adapter policy + telemetry enforcement (no code extraction)

## Approach

Do not extract shared auth logic. Instead, audit every adapter's auth
resolution against a documented policy, fix the three adapters with silent
vault omissions (Gemini, Bedrock primary secret, Azure non-key fields) by
adding vault legs inline, remove the `Code.ensure_loaded?` guards, and enforce
correctness going forward via a telemetry-based test that asserts every
adapter's `stream/3` emits a `[:tau, :vault, :get]` event (or a documented
`:skipped` tag) before returning its first event. A new `SPEC-PROVIDERS-AUTH`
section in `docs/spec/SPEC-USER-TURN.md` (or a dedicated `docs/adr/ADR-00XX`)
documents the expected vault position for each adapter. The policy is enforced
by a property-based test that stubs `Tau.Settings.Vault` and asserts that each
adapter honours it. Copilot's custom OAuth shape is documented as the lone
policy exception.

## Rationale

The complecting hypothesis claims credential resolution is woven into each
adapter. This proposal challenges the premise that extraction is necessary:
the woven concern is not inherently bad if each adapter's woven logic is
correct, minimal, and verified by tests. The acceptance criterion is met not
by sharing code but by sharing a documented, tested invariant ("vault is at
position 2 in every adapter's chain"). The `Code.ensure_loaded?` guards are
bugs, not design — they should be deleted rather than wrapped. This is a
behaviour-correcting (not extraction) approach: fix the wrong implementations
in place, document the policy, test it per adapter. Decomplecting: instead
of pulling out shared code, this proposal makes the policy an explicit artifact
(ADR + test) that new adapter authors can read and follow, removing the
complect between "the adapter" and "the undocumented chain convention."

## Sketch

**Inline fix (Gemini, adding vault leg):**
```elixir
# lib/tau/providers/gemini.ex — after
defp api_key do
  Application.get_env(:tau, __MODULE__, [])[:api_key] ||
    Tau.Settings.Vault.resolve({:vault, "GOOGLE_API_KEY"}) ||
    System.get_env("GOOGLE_API_KEY") ||
    System.get_env("GEMINI_API_KEY")
end
```

**Inline fix (Mistral/DeepSeek/Groq — remove Code.ensure_loaded? guard):**
```elixir
# lib/tau/providers/mistral.ex — after
defp api_key do
  Application.get_env(:tau, __MODULE__, [])[:api_key] ||
    Tau.Settings.Vault.resolve({:vault, "MISTRAL_API_KEY"}) ||
    System.get_env("MISTRAL_API_KEY")
end
# vault_key/0 private function deleted entirely
```

**Policy document (ADR or SPEC section):**
```
## Auth resolution policy (ADR-00XX or SPEC-USER-TURN §N)

Every production adapter MUST resolve its primary API secret via the
following priority chain:

  1. Explicit per-call opt (`:api_key` or equivalent)
  2. `Application.get_env(:tau, adapter_module)[:api_key]`  (app env)
  3. `Tau.Settings.Vault.resolve({:vault, "<ADAPTER_ENV_VAR_NAME>"})`
  4. `System.get_env("<ADAPTER_ENV_VAR_NAME>")`             (fallback)

Deviations from this chain MUST be documented in this table:

| Adapter        | Primary secret     | Vault name            | Exception                          |
|----------------|--------------------|-----------------------|------------------------------------|
| Anthropic      | OAuth or api_key   | ANTHROPIC_API_KEY     | OAuth leg after vault              |
| Bedrock        | AWS key triple     | AWS_ACCESS_KEY_ID     | :aws_credentials library leg added |
| Gemini         | api_key            | GOOGLE_API_KEY        | none                               |
| Mistral        | api_key            | MISTRAL_API_KEY       | none                               |
| Groq           | api_key            | GROQ_API_KEY          | none                               |
| DeepSeek       | api_key            | DEEPSEEK_API_KEY      | none                               |
| AzureOpenAI    | api_key            | AZURE_OPENAI_API_KEY  | endpoint/deployment: no vault leg  |
| Custom         | api_key            | (user-defined)        | base_url: no vault leg             |
| Copilot        | OAuth              | (not applicable)      | two-token model; see SPEC-COPILOT  |
```

**Property test asserting vault coverage:**
```elixir
defmodule Tau.Providers.AuthPolicyTest do
  use ExUnit.Case, async: false

  @adapters [
    Tau.Providers.Anthropic,
    Tau.Providers.Gemini,
    Tau.Providers.Mistral,
    Tau.Providers.Groq,
    Tau.Providers.DeepSeek,
    Tau.Providers.AzureOpenAI,
    Tau.Providers.Custom
  ]

  setup do
    # Instrument vault get calls
    :ok = :telemetry.attach_many(
      "test-vault-#{System.unique_integer()}",
      [[:tau, :vault, :get]],
      fn event, measurements, metadata, acc_pid ->
        send(acc_pid, {:vault_call, metadata.name_hash})
      end,
      self()
    )
    :ok
  end

  for adapter <- @adapters do
    test "#{inspect(adapter)} calls Tau.Settings.Vault before falling back to System.get_env" do
      # Ensure app env and vault miss, but env var present
      Application.delete_env(:tau, unquote(adapter))

      # stream/3 will fail (no real API), but vault telemetry fires before network
      _ = unquote(adapter).stream([], %{}, %{})

      assert_received {:vault_call, _},
        "#{inspect(unquote(adapter))} did not emit [:tau, :vault, :get] during stream/3"
    end
  end
end
```

**File changes:**
- `lib/tau/providers/gemini.ex` — add vault leg (~2 lines)
- `lib/tau/providers/mistral.ex`, `deepseek.ex`, `groq.ex` — remove `vault_key/0`, inline vault call (~-5 lines each)
- `lib/tau/providers/azure_openai.ex` — remove `vault_key/0`, inline vault call
- `lib/tau/providers/custom.ex` — remove `vault_key/0`, inline vault call
- `docs/adr/ADR-00XX-auth-resolution-policy.md` — new ADR
- `test/tau/providers/auth_policy_test.exs` — new cross-adapter property test

## Tradeoffs

### Strengths

- Smallest code surface change: no new modules, no behaviour changes, no API breakage.
- The telemetry-based test creates a regression gate that is adapter-agnostic — a future adapter that omits the vault leg will fail the test without any code change to the test.
- The policy document (ADR) is the canonical reference that satisfies the acceptance criterion's "predictable without reading source" requirement at low code cost.
- Preserves each adapter's structural autonomy: Bedrock, Copilot, and AzureOpenAI can keep their specialist shapes without being forced into a one-size-fits-all utility module interface.

### Weaknesses

- Does not remove the duplication of the chain logic itself: each adapter still has a private `api_key/0` or inline chain expression. A future adapter author can still get the order wrong.
- The telemetry-based test is indirect: it asserts that vault telemetry fires, not that the vault result is used correctly. An adapter could call `Tau.Settings.Vault.get/1` and discard the result — the test would pass.
- The policy table in the ADR is a documentation artefact that drifts from code over time unless the test is the canonical enforcement (it is not — the test checks telemetry, not table conformance).
- `Code.ensure_loaded?` guards are removed but replaced with nothing — if `Tau.Settings.Vault` is ever conditionally compiled (e.g. a stripped release), the adapters will compile-error rather than degrade gracefully. (This is arguably the correct behaviour, but it changes the failure mode.)
- Azure's `endpoint` and `deployment` fields remain without vault legs per the policy table; this is a documented partial fix, but it is a partial fix.

### Costs

- Minimal: 6 adapter files with small edits; 1 new test file; 1 new ADR.
- No migration cost for callers.
- CI vault-telemetry test adds a small overhead per adapter tested (each does a network-failing `stream/3` call; mocking required for speed).

## Dependencies

- `Tau.Settings.Vault` must be available in the test environment for the telemetry test (it already is via `ExUnit` application start in `mix test`).
- The telemetry attachment pattern in `test/support/` should be extracted to a shared test helper if it doesn't already exist.

## Confidence

medium — Inline fixes are low-risk and Anthropic's `Auth` module is a working
precedent that unconditional vault calls are safe. Confidence in the telemetry
test mechanism is constrained to medium: it is indirect (telemetry event ≠ used
result); a stronger assertion would mock `Tau.Settings.Vault.resolve/1` and
assert the return value is threaded into the request, which requires more test
setup. That stronger form would raise confidence to high.

## Prior art / references

- Elixir telemetry-driven testing: `Phoenix.Logger` test suite instruments telemetry events to assert log behaviour without coupling to implementation.
- ADR as policy enforcement artifact: AWS Well-Architected Framework credentials chapter — documents expected chain without mandating a shared library.
- Hickey "Simple Made Easy" — the "simple" alternative to extraction is sometimes documentation + tests, when the concern is small and the pieces fit together without a new composition layer.
- `lib/tau/providers/anthropic/auth.ex` — unconditional `Tau.Settings.Vault.resolve/1` call with no guard, as the reference implementation to replicate.
