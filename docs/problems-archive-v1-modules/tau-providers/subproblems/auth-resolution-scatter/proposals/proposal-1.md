---
template_version: 1
template_name: proposal
proposal_id: 1
parent_problem: ../problem.md
---

# Proposal 1: Tau.Providers.Auth shared utility module

## Approach

Extract a single `Tau.Providers.Auth` module that provides a
`resolve_api_key/3` function covering the three-step priority chain
(app env → vault → system env) and a `resolve_or_error/3` wrapper
that converts nil to `{:error, :missing_api_key}`. Every adapter that
currently embeds a private `api_key/0` / `vault_key/0` function pair
replaces those functions with a call to `Tau.Providers.Auth.resolve_api_key/3`.
The `Code.ensure_loaded?` guards in Mistral, DeepSeek, Groq, AzureOpenAI,
and Custom are deleted; `Tau.Settings.Vault` is always called unconditionally
through the shared module. Gemini and Bedrock gain vault legs for their
primary secret fields (GOOGLE_API_KEY and AWS credentials respectively).
The existing `Tau.Providers.Anthropic.Auth` module is kept as-is (it handles
OAuth complexity that exceeds the shared module's scope); the shared module
handles only the simpler API-key chain for the remaining adapters.

## Rationale

The complecting hypothesis states that the credential priority chain is
woven into each adapter module. This proposal decomplects by pulling the
shared chain logic into one place — adapters become callers, not
re-implementers. The `Code.ensure_loaded?` guard is the observable symptom of
the complecting: it exists in each adapter because there is no single owner of
the vault call. Centralising vault access in `Tau.Providers.Auth` removes the
guard entirely — there is one place to test whether the vault is called, one
place to fix a vault bug, and one place to add telemetry for auth resolution
events. The acceptance criterion (predictable vault honoring across adapters)
is met because every standard API-key adapter goes through the same path.

## Sketch

```elixir
defmodule Tau.Providers.Auth do
  @moduledoc """
  Shared credential-resolution chain for provider adapters.

  Standard three-step priority: explicit opt → vault → system env.
  Call `resolve_api_key/3` from a provider's `stream/3` entry point.
  """

  @doc """
  Resolve an API key using the standard provider priority chain.

  ## Parameters
  - `app_env_key` — the atom key under `Application.get_env(:tau, adapter_module)`
  - `vault_name`  — the vault credential name (e.g. `"MISTRAL_API_KEY"`)
  - `env_var`     — the fallback `System.get_env` name (e.g. `"MISTRAL_API_KEY"`)

  Returns the first non-nil, non-empty string found, or `nil`.
  """
  @spec resolve_api_key(module(), String.t(), String.t()) :: String.t() | nil
  def resolve_api_key(adapter_module, vault_name, env_var) do
    Application.get_env(:tau, adapter_module, [])[:api_key] ||
      Tau.Settings.Vault.resolve({:vault, vault_name}) ||
      System.get_env(env_var)
  end

  @doc "resolve_api_key/3 wrapped as a tagged tuple; returns {:error, :missing_api_key} on nil."
  @spec resolve_api_key_or_error(module(), String.t(), String.t()) ::
          {:ok, String.t()} | {:error, :missing_api_key}
  def resolve_api_key_or_error(adapter_module, vault_name, env_var) do
    case resolve_api_key(adapter_module, vault_name, env_var) do
      nil -> {:error, :missing_api_key}
      "" -> {:error, :missing_api_key}
      key -> {:ok, key}
    end
  end
end
```

**Adapter call-site change (Mistral example):**
```elixir
# Before
defp api_key do
  Application.get_env(:tau, __MODULE__, [])[:api_key] ||
    vault_key() ||
    System.get_env("MISTRAL_API_KEY")
end

defp vault_key do
  if Code.ensure_loaded?(Tau.Settings.Vault) do
    Tau.Settings.Vault.resolve({:vault, "MISTRAL_API_KEY"})
  end
end

# After (both private functions removed)
defp api_key do
  Tau.Providers.Auth.resolve_api_key(__MODULE__, "MISTRAL_API_KEY", "MISTRAL_API_KEY")
end
```

**Gemini addition (vault leg added):**
```elixir
# Before
defp api_key do
  Application.get_env(:tau, __MODULE__, [])[:api_key] ||
    System.get_env("GOOGLE_API_KEY") || System.get_env("GEMINI_API_KEY")
end

# After (vault leg inserted; GOOGLE_API_KEY is the primary env var name)
defp api_key do
  Tau.Providers.Auth.resolve_api_key(__MODULE__, "GOOGLE_API_KEY", "GOOGLE_API_KEY") ||
    System.get_env("GEMINI_API_KEY")
end
```

**File changes:**
- `lib/tau/providers/auth.ex` — new file (~50 lines)
- `lib/tau/providers/mistral.ex` — delete `vault_key/0`, simplify `api_key/0`
- `lib/tau/providers/deepseek.ex` — same
- `lib/tau/providers/groq.ex` — same
- `lib/tau/providers/azure_openai.ex` — `api_key` leg of `resolve_config/0`
- `lib/tau/providers/custom.ex` — `api_key` leg of `resolve_config/0`
- `lib/tau/providers/gemini.ex` — add vault leg to `api_key/0`
- `lib/tau/providers/bedrock.ex` — add vault option for `AWS_ACCESS_KEY_ID` (or document as out-of-scope per problem.md)
- `test/tau/providers/auth_test.exs` — new unit + property tests

## Tradeoffs

### Strengths

- Deletes the `Code.ensure_loaded?` guard at all five call sites in one pass; no new instances can appear at new adapters if they follow the pattern.
- Single place to test vault honoring — one property test covers all adapters indirectly.
- Incremental: adapters migrate independently; no big-bang rewrite required.
- No behaviour change to `Tau.Provider` callbacks; zero API breakage to callers.
- `Tau.Providers.Anthropic.Auth` complexity (OAuth, error descriptions) is left untouched.

### Weaknesses

- Does not address Bedrock's structurally different credential shape (AWS key triple vs single API key); Bedrock gets only a partial fix (the env guard remains around the `:aws_credentials` library leg, which is legitimately optional).
- The `resolve_api_key/3` signature forces caller-provided `vault_name` and `env_var` strings, meaning a typo in any adapter is still a silent per-adapter defect — it just moves the defect from logic to data.
- Does not remove the dead `configure/1` callback; that's a separate concern per the problem statement but leaves a confusing interface standing.
- Gemini's dual env-var fallback (`GOOGLE_API_KEY` vs `GEMINI_API_KEY`) requires a small adapter-specific wrapper that slightly undermines the uniformity story.

### Costs

- 1 new file; 6 adapter files modified; 1 new test file.
- Zero breaking changes to public API.
- Migration reviewable in one PR.
- No new dependencies.

## Dependencies

- `Tau.Settings.Vault` already exists and is already called unconditionally from `Tau.Providers.Anthropic.Auth`; no precondition work needed.
- The `Code.ensure_loaded?` guards exist because vault was once optional; removing them is safe only if `Tau.Settings.Vault` compiles unconditionally in all mix envs. Verification: `grep -r "Code.ensure_loaded?(Tau.Settings.Vault)" lib/` returns the five adapter sites; none appear in `mix.exs` conditional compilation blocks.

## Confidence

medium — The approach is straightforward and the Anthropic.Auth precedent is
an existence proof that unconditional vault calls work. Confidence would rise
to high after verifying that `mix compile --no-deps-check` in a fresh env with
no optional deps still loads `Tau.Settings.Vault`.

## Prior art / references

- `lib/tau/providers/anthropic/auth.ex` — unconditional vault call without `Code.ensure_loaded?` guard; this is the pattern being generalised.
- Elixir `Application.get_env` + `||` chain idiom is standard across the Tau codebase.
- Hickey "Simple Made Easy" — extraction axis: move shared logic to a separate entity rather than duplicating it.
