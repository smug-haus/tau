---
name: tau-toolchain
description: Install and verify the Erlang/OTP + Elixir + Hex + rebar3 toolchain Tau needs to build. Use whenever a session starts with `mix` or `elixir` not on PATH, when `mix compile` / `mix test` / `mix format` fail with "command not found", when the user asks you to set up the BEAM, or when CI failures suggest a toolchain mismatch with `.tool-versions`.
---

# tau-toolchain — install BEAM + Elixir for this repo

This skill is the canonical answer to "how do I get `mix` working in this
repo". **Read it before re-deriving anything.**

## TL;DR

```sh
sudo bash scripts/install-toolchain.sh
. /etc/profile.d/elixir.sh
elixir --version    # → Elixir 1.18.1 (compiled with Erlang/OTP 27)
mix --version       # → Mix 1.18.1
```

That installs Erlang/OTP 27.2, Elixir 1.18.1, Hex archive, and rebar3 —
**without using apt** and without any `--unsafe` flags. Versions are pinned
from `.tool-versions`.

If `mix compile` then fails because `deps/` is empty, run `mix deps.get`
first.

## Why a script (and not asdf / mise / apt)

- `apt install elixir` ships a stale 1.14 — too old for this repo (`~> 1.17`).
- `asdf install erlang 27.2` would compile from source (~10 min) and needs
  `-dev` headers (still needs apt).
- `mise` is fine for human dev machines but adds a runtime dependency.

The script downloads precompiled binaries from sources the BEAM ecosystem
already publishes:

| Component | Source | URL |
|-----------|--------|-----|
| Erlang/OTP 27.2 | builds.hex.pm (same as `erlef/setup-beam`) | `https://builds.hex.pm/builds/otp/ubuntu-24.04/OTP-27.2.tar.gz` |
| Elixir 1.18.1 (otp-27) | elixir-lang/elixir GitHub release | `https://github.com/elixir-lang/elixir/releases/download/v1.18.1/elixir-otp-27.zip` |
| Hex archive | builds.hex.pm | `https://builds.hex.pm/installs/1.18.0/hex.ez` |
| rebar3 | erlang/rebar3 GitHub release | `https://github.com/erlang/rebar3/releases/latest/download/rebar3` |

All four are reachable via curl.

## What `mix` commands work and what they verify

| Command | Verifies | Needs deps/ |
|---------|----------|-------------|
| `mix deps.get` | Fetch deps from Hex | — (populates `deps/`) |
| `mix compile --warnings-as-errors` | code compiles, no warnings | yes |
| `mix format --check-formatted` | code is `mix format`-clean | no (formatter is bundled) |
| `mix credo --strict` | static analysis | yes (credo is a dep) |
| `mix dialyzer` | typespec discrepancies | yes |
| `mix test` | unit + integration tests | yes |
| `mix test --only property` | StreamData property suite | yes |
| `mix escript.build` | escript bundles | yes |

`mix format` is the only entry that's safe in a fresh checkout — the rest
need `deps/` populated, which is what `mix deps.get` is for.

## Python 3.10 (build-only, ex_termbox)

`ex_termbox` (transitive via `ratatouille`, `only: [:dev]`) needs a `python`
binary on PATH at compile time — not at runtime. Python 3.11+ removed the
`'rUb'` file-open mode that the vendored `waf` script depends on (`ValueError:
invalid mode: 'rUb'`). Python 3.10 still accepts it as a deprecated alias.

Pinned in `.python-version`. Recommended setup:

```sh
pyenv install                      # reads .python-version
python -m venv .venv               # per-dev venv (.venv/ is gitignored)
source .venv/bin/activate
mix compile                        # ex_termbox waf finds .venv/bin/python
```

`MIX_ENV=prod mix release` does not need Python — TUI is dev-only — so
escript-shaped binary releases are unaffected when Python isn't available.

See `CONTRIBUTING.md` § "Build prerequisites" for the full story; issue #136
tracks the underlying waf incompatibility.

## When you DON'T need this skill

- The user asked a code question that doesn't require running tests.
- `elixir --version` already prints `1.18.1 (compiled with Erlang/OTP 27)`.
- You just need to read or edit `.ex` / `.exs` files.

In those cases, skip installation and work directly.

## Versions

Single source of truth: `.tool-versions` at the repo root. The install
script honours `ERLANG_VERSION` / `ELIXIR_VERSION` / `ELIXIR_OTP_MAJOR`
env overrides if they ever drift; bump them in `.tool-versions` first
and re-run the script.

## Slash command

`/install-toolchain` runs `scripts/install-toolchain.sh` and prints the
verification banner. Use it when starting a session that will need to
compile or run tests.
