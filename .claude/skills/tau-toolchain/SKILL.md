---
name: tau-toolchain
description: Install and verify the Erlang/OTP + Elixir + Hex + rebar3 toolchain Tau needs to build. Use whenever a session starts with `mix` or `elixir` not on PATH, when `mix compile` / `mix test` / `mix format` fail with "command not found", when the user asks you to set up the BEAM, or when CI failures suggest a toolchain mismatch with `.tool-versions`. Also covers what Mix operations DO NOT work inside the Anthropic sandbox (`mix deps.get`) and the verified workaround.
---

# tau-toolchain — install BEAM + Elixir for this repo

This skill is the canonical answer to "how do I get `mix` working in this
sandbox". **Read it before re-deriving anything.**

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

If `mix compile` then fails because `deps/` is empty, see
**"Fetching deps"** below — it does NOT work inside the sandbox.

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

All four are reachable via curl from inside the sandbox.

## Sandbox limitation: Erlang TLS is blocked, curl is not

The Anthropic sandbox MITMs all outbound HTTPS via an `egress-gateway-ca`
(`O=Anthropic; CN=sandbox-egress-production TLS Inspection CA`). curl
negotiates a TLS fingerprint the proxy accepts, so direct downloads work.

**Erlang's `:httpc` consistently gets `502 Bad Gateway` /
`503 Service Unavailable` from the proxy on every HTTPS host** — verified
against `hex.pm`, `cdn.jsdelivr.net`, `github.com`, `google.com`. The
proxy's response body is the Envoy-style
`upstream connect error or disconnect/reset before headers`.

This is **not** fixable from Mix config. `HEX_MIRROR`, `HEX_CACERTS_PATH`,
`HEX_UNSAFE_HTTPS=1`, custom `HEX_HTTP_*` retry tuning, and TLS 1.2/1.3
toggles all yield the same 5xx. The proxy distinguishes Erlang's TLS hello
from curl's and refuses to relay it.

References:
- [openai/codex#10502](https://github.com/openai/codex/issues/10502) —
  same symptom on a different sandbox vendor; confirms it is a proxy
  policy, not a hex.pm outage.
- [hexpm/hex docs — mirrors](https://hex.pm/docs/mirrors) — official
  mirror list (Fastly, jsDelivr, UPYUN). All three fail from Erlang
  inside this sandbox.

### Implications

- `mix local.hex --force` ❌ (Mix uses :httpc → blocked)
- `mix local.rebar --force` ❌ (same)
- `mix deps.get` ❌ (same)
- `mix hex.search`, `mix hex.info <pkg>` ❌ (same)
- `mix compile`, `mix test`, `mix format`, `mix credo`, `mix dialyzer` ✅
  — provided `deps/` is populated. None of these need network.
- `iex -S mix` ✅
- `escript`, `mix escript.build` ✅

The install script handles `local.hex` / `local.rebar` by downloading the
Hex archive via curl and dropping rebar3 into `~/.mix/rebar3` directly,
which is where Mix looks for them.

## Fetching deps

`mix deps.get` does not work in the sandbox. Two reliable alternatives:

### Option A — push and let CI fetch

Make the change locally, push the branch, let GitHub Actions run
`mix deps.get` + `mix test` + `mix dialyzer`. The CI workflow at
`.github/workflows/ci.yml` is configured exactly for this.

This is the right path **for any work that needs `mix test` to pass**.
Don't pretend you ran the test suite inside the sandbox if you didn't —
say so and rely on CI.

### Option B — fetch deps via curl on a host with working egress

If a checkout of this repo with a populated `deps/` and `_build/` exists
elsewhere (a dev machine, a previous CI artifact), tar it up and copy it
in. The `deps/` tree is self-contained — once present, every `mix`
command that doesn't reach the network just works.

There is no third option that bypasses `:httpc` from inside this sandbox.
Don't waste tokens trying to make `HEX_MIRROR=https://...` work — see the
references above.

## What `mix` commands work and what they verify

| Command | Verifies | Needs deps/ |
|---------|----------|-------------|
| `mix compile --warnings-as-errors` | code compiles, no warnings | yes |
| `mix format --check-formatted` | code is `mix format`-clean | no (formatter is bundled) |
| `mix credo --strict` | static analysis | yes (credo is a dep) |
| `mix dialyzer` | typespec discrepancies | yes |
| `mix test` | unit + integration tests | yes |
| `mix test --only property` | StreamData property suite | yes |
| `mix escript.build` | escript bundles | yes |

## Common Mix commands

Day-to-day workflow once `deps/` is populated. Sandbox reachability
annotated.

| Command | Purpose | Sandbox |
|---------|---------|---------|
| `mix deps.get` | Fetch deps from Hex | ❌ (use CI / prepopulated tree) |
| `mix compile` | Build (treat warnings-as-errors) | ✅ |
| `mix format --check-formatted` | CI gate: formatter | ✅ |
| `mix credo --strict` | CI gate: static analysis | ✅ |
| `mix dialyzer` | CI gate: typespecs | ✅ |
| `mix test` | ExUnit suite | ✅ |
| `mix test --only property` | StreamData property suite (longer budget) | ✅ |
| `mix tau.hello` | one-shot smoke test against a provider | ✅ |
| `mix escript.build && ./tau` | local TUI run | ✅ |
| `iex -S mix` | REPL: `Tau.start_session/1` etc. | ✅ |

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
