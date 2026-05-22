# ADR-0016: Credential custody is the OS, not Tau

- **Status:** Accepted
- **Date:** 2026-05-01
- **Deciders:** the agent loop, with no objection from @smug-haus
- **Related:**
  - Issues: #66
  - Code: `lib/tau/settings/vault.ex`,
    `lib/tau/settings/vault/env.ex`,
    `lib/tau/settings/vault/keychain/{mac,linux,windows}.ex`,
    `lib/tau/providers/anthropic.ex`
  - Prior ADRs this builds on: ADR-0002 (settings flow through
    `Tau.Settings.Cache`, never `Application.get_env/2`)

## Context

Today every provider reads its API key with `System.get_env/1` plus
an `Application.get_env/2` fallback. A user who can read the user's
home directory or `/proc/<pid>/environ` can read every credential
Tau ever touches. Issue #66 (surfaced by the AlexClaw critic note)
proposes encryption-at-rest for credentials.

The naive read of "encryption-at-rest" is "AES-256-GCM with a
file-based unlock key" — `:crypto` makes the cipher half trivial.
That is **security theatre on a single-user laptop**: the unlock
key is another file on disk, owned by the same user, readable by
the same processes. We have moved the problem, not solved it.

The only mechanism that materially raises the bar is **OS-level
key custody**: macOS Keychain, freedesktop libsecret (GNOME
Keyring / KWallet), Windows DPAPI. The OS gates access by user
session and (on macOS) by signed binary identity. The TypeScript
reference (`pi-mono`) does not have this; we are choosing to add
it because BEAM apps shell out to a tiny set of platform tools
cleanly without a NIF.

A second design force: Tau runs **headless** (CI, agents,
containers) at least as often as it runs interactively. A startup
master-password prompt is unacceptable in CI; a "fall through to
env if no keychain" path is mandatory.

## Decision

Tau delegates credential custody to the operating system through a
`Tau.Settings.Vault` behaviour with three platform backends and an
`Env` passthrough. Tau **never owns long-lived ciphertext** of any
credential.

Specifics:

- `Tau.Settings.Vault` is a behaviour with `get/1`, `put/2`,
  `list/0`. The public API in the same module dispatches to a
  backend chosen from `Tau.Settings.Cache.get()[:vault][:backend]`,
  defaulting to `:env`. Configuration flows through the cache, not
  `Application.get_env/2` (ADR-0002).
- `Tau.Settings.Vault.Env` is the default. `get/1` calls
  `System.get_env/1`. `put/2` is `{:error, :read_only}`. This
  preserves today's behaviour byte-for-byte for headless / CI.
- `Tau.Settings.Vault.Keychain.Mac` shells out to
  `/usr/bin/security` (`add-generic-password -U`,
  `find-generic-password -w`, `delete-generic-password`). Service
  name `"tau"`, account `name`. No NIF, no extra dep.
- `Tau.Settings.Vault.Keychain.Linux` shells out to `secret-tool`
  from `libsecret-tools`. If `secret-tool` is not on PATH at the
  time the call is made, `get/1` and `put/2` return
  `{:error, :secret_tool_unavailable}` — fail-loud, never silently
  fall through to env.
- `Tau.Settings.Vault.Keychain.Windows` is **stubbed** at
  `{:error, :not_implemented}`. DPAPI access without a NIF is
  non-trivial; a follow-up issue tracks the real implementation.
- The `:auto` backend resolver picks based on `:os.type/0` and
  falls through to `Env` for unrecognised platforms.
- Settings reference credentials by name only:
  `{vault: "anthropic_api_key"}`. `Tau.Settings.Vault.resolve/1`
  takes a literal string or `{:vault, name}` and returns the
  resolved value.
- Telemetry event `[:tau, :vault, :get]` carries
  `%{backend: atom, result: :ok | :not_found | :error}` and a
  **truncated SHA-256 of the name** as `name_hash`. The credential
  value is **never** in metadata, logs, or error tuples.

## Consequences

Upsides:

- A user on a multi-tenant macOS box can put `ANTHROPIC_API_KEY`
  in Keychain and Tau no longer has the key in its env. A `ps
  auxe` will not surface it.
- The Env default is unchanged behaviour for everyone today —
  zero-config migration.
- Backends are pluggable; a future user can implement a Vault for
  Hashicorp / 1Password CLI / `pass` without touching core.

Costs:

- Shelling out to `security(1)` and `secret-tool` is slower than
  reading an env var. We accept it: credential reads happen at
  most once per session start, not in the hot path.
- macOS Keychain prompts the user for permission the first time
  (and on signed-binary-identity changes). This is OS UX, not
  ours; users opt into it knowingly.
- We forego the option of "encrypted credentials file in the
  repo" — explicitly. Anyone who wants that can build it as a
  separate Vault backend, but core ships nothing of the sort.

## Alternatives considered

1. **AlexClaw's "AES-256-GCM with a file-based unlock key".**
   Rejected. The unlock key is another file on the same disk,
   owned by the same user, readable by the same processes. The
   threat model that defeats env vars (local read access) defeats
   this too. Encryption without OS-level key custody is theatre.

2. **Master-password prompt at startup.** Rejected. Tau runs
   headless at least as often as interactively (CI, agent
   harnesses, devcontainers). A blocking TTY prompt makes Tau
   un-runnable in those modes. Adding a `--password-stdin` flag
   shifts the prompt to the parent process, which is back to the
   "another file on disk" problem.

3. **NIF-based DPAPI / Keychain bindings.** Deferred. NIFs add
   cross-compile complexity (Burrito releases ship platform
   binaries; an inline NIF means three more cross-build matrices)
   and a crash domain we do not need. `security(1)` and
   `secret-tool` are stable, signed system tools; calling them is
   strictly safer than linking their libraries. Windows DPAPI is
   the one platform where the shell-out story is weak — we ship
   a stub there until the NIF question is tackled directly.

4. **Per-provider config files with restricted permissions
   (`chmod 600`).** Already the case for `~/.tau/settings.json`,
   and not enough on its own — see the threat model above.

## Notes

- The acceptance criterion in #66 — "round-trip a credential
  through the macOS Keychain backend without it appearing in any
  process state, log, or transcript" — is structurally satisfied
  by the design (no value crosses telemetry / logs / event
  metadata). Live macOS validation is the maintainer's manual
  smoke test; CI cannot exercise a real keychain.
- Wiring providers is incremental. This ADR wires
  `Tau.Providers.Anthropic` end-to-end as the demonstration; other
  providers may follow the same pattern, but none of the surface
  contracts above depend on them doing so.
