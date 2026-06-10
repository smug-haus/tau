---
template_version: 1
template_name: problem
node_kind: leaf
depth: 1
parent: ../../problem.md
status: draft
---

# Problem: auth-resolution-scatter

## Statement

Every production adapter implements its own credential priority chain (app env →
vault → env var) as private helper functions, with no shared behaviour, module,
or scaffold. The vault leg specifically is guarded by a `Code.ensure_loaded?/1`
conditional in each adapter that implements it, but three adapters
(Anthropic, Bedrock, Gemini) skip the vault leg entirely, creating silent
inconsistency: operators who configure credentials via `Tau.Settings.Vault`
find those credentials honoured by some adapters and silently ignored by others.

## Context

- `lib/tau/providers/anthropic.ex` — delegates to `Tau.Providers.Anthropic.Auth`
  (a dedicated module); vault integration is via `Tau.Settings.Vault.resolve/1`
  inside `Auth`, which IS loaded unconditionally (no `Code.ensure_loaded?` guard
  present in `auth.ex`).
- `lib/tau/providers/bedrock.ex:180-200` — `credentials/0` reads AWS env vars
  (`AWS_ACCESS_KEY_ID`) or optional `:aws_credentials` library; no
  `Tau.Settings.Vault` integration at all. Vault is silently absent.
- `lib/tau/providers/gemini.ex:171-179` — `api_key/0` checks only
  `Application.get_env` and `System.get_env`; no vault leg.
- `lib/tau/providers/mistral.ex:88-98` — `api_key/0` has the pattern:
  `app_env || vault_key() || System.get_env`; `vault_key/0` uses
  `Code.ensure_loaded?` guard. Vault present but guarded.
- `lib/tau/providers/deepseek.ex:95-106` — same vault-guarded pattern as Mistral.
- `lib/tau/providers/groq.ex:88-104` — same vault-guarded pattern.
- `lib/tau/providers/azure_openai.ex:127-155` — `resolve_config/0` uses
  vault-guarded pattern for `api_key`; endpoint/deployment/api_version have no
  vault leg.
- `lib/tau/providers/custom.ex:130-154` — `resolve_config/0` uses vault-guarded
  pattern for `api_key`; `base_url` has no vault leg.
- `lib/tau/providers/copilot/auth.ex` — distinct two-token model (OAuth
  long-lived + short-lived API token via `TokenStore`); no standard vault chain
  applicable.
- The `@optional_callbacks [configure: 1, ...]` in `lib/tau/provider.ex:131`
  suggests `configure/1` was intended as the auth-resolution hook, but none
  of the adapters above use it for credentials; they each embed the chain
  privately.

## Complecting hypothesis

1. **Credential priority ordering is complected with each adapter module:**
   whether vault is consulted, and in which position, varies per adapter
   with no shared enforcement. A bug in the vault leg (e.g. the
   `Code.ensure_loaded?` guard returning false at unexpected times) will
   manifest differently — or not at all — depending on which adapter is active.
2. **The `configure/1` optional callback is complected with undocumented
   disuse:** it exists in the behaviour as the intended auth-configuration
   seam but is never used by any production adapter, making it dead interface
   surface that misleads new adapter authors about where credential logic
   belongs.

## Decomposition strategy

(leaf — no further decomposition; proceed to proposals)

## Acceptance criterion

Every production adapter consults `Tau.Settings.Vault` for its primary secret
credential (API key, OAuth token, or equivalent) in a consistent, observable
priority position — either via a shared `Tau.Providers.Auth` utility or via
documented per-adapter policy — such that an operator who configures vault
credentials can predict, without reading each adapter's source, whether those
credentials will be honoured.

## Out of scope

- Copilot's two-token model internals (OAuth exchange, `TokenStore`) — the
  auth topology is legitimately distinct; the acceptance criterion requires
  only that vault integration follows the same priority position as other
  adapters for the OAuth token lookup.
- AWS Bedrock SigV4 signing logic — transport security, not credential
  resolution.
- Event sequencing and usage normalisation — covered by sibling sub-problems.
- Capabilities flags — covered by `capabilities-flag-fidelity`.

## Amendment log

- (none yet)
