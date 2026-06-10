---
template_version: 1
template_name: problem
node_kind: leaf
depth: 1
parent: ../../problem.md
status: draft
---

# Problem: tau init wizard discards providers and uses wrong Bedrock credential key

## Statement

`tau init`'s provider selection step presents a multi-select prompt but then
calls `List.first(providers)` when building `new_settings`, silently discarding
every provider the user selected except the first. Separately, `@providers` in
`Tau.CLI.Init` maps Bedrock to `AWS_ACCESS_KEY_ID`, while
`Tau.Commands.Builtin.Logout.@credential_map` maps `"bedrock"` to
`AWS_SECRET_ACCESS_KEY`. A user who stores a Bedrock credential via `tau init`
and then runs `/logout bedrock` removes a different vault entry than was stored;
the actual stored credential is never cleared.

## Context

- `lib/tau/cli/init.ex:152–153` — `Map.put(... "provider", providers |> List.first() |>
  provider_string())` — `List.first/1` discards all but the first element of
  the `providers` list returned by `provider_selection/1`.
- `lib/tau/cli/init.ex:136–139` — `provider_selection/1` correctly returns a
  list of selected keys; the multi-select prompt at line 203 reads "[1/5]
  Which providers do you want to enable?" (plural).
- `lib/tau/cli/init.ex:60–65` — `@providers` for `:bedrock` sets
  `env: "AWS_ACCESS_KEY_ID"`.
- `lib/tau/commands/builtin/logout.ex:38–43` — `@credential_map` maps
  `"bedrock" => "AWS_SECRET_ACCESS_KEY"`.
- These two are the only places in the codebase that map the "bedrock"
  provider identity to a vault credential name; they disagree on the key.
- `Tau.Settings.Vault.put/2` and `Tau.Settings.Vault.delete/1` operate on the
  vault key name directly — no indirection normalises this divergence at runtime.

## Complecting hypothesis

- Provider identity is complected with credential-key knowledge in two separate
  modules: `Init.@providers` owns the "what to store" side and
  `Logout.@credential_map` owns the "what to remove" side, with no shared
  source of truth, so they drift independently.

## Decomposition strategy

(leaf — no further decomposition; proceed to proposals)

## Acceptance criterion

After a `tau init` run where the user selects N > 1 providers, the written
`settings.local.json` reflects all N selections; AND `tau init` and
`/logout bedrock` use the same vault credential key name for Bedrock, so that
credentials stored during init can be removed by logout.

## Out of scope

- `provider_string/1` divergence from `Atom.to_string/1` (style; no behaviour
  change)
- `handle_one_credential/3` `tap/2` readability issue
- `validate/1` schema-resolve performance (re-resolving on every call)
- Multi-provider persistence in `settings.json` format — whether the settings
  schema supports a list of providers is a schema question, not a wizard question;
  the fix may be to correct the prompt or to persist a list depending on schema
  support
- Logout behaviour for providers other than Bedrock

## Amendment log

- (none yet)
