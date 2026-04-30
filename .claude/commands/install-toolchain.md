---
description: Install Erlang/OTP 27.2 + Elixir 1.18.1 + Hex + rebar3 from precompiled binaries (no apt). Idempotent.
allowed-tools: Bash(sudo bash scripts/install-toolchain.sh), Bash(bash scripts/install-toolchain.sh), Bash(. /etc/profile.d/elixir.sh && elixir --version), Bash(. /etc/profile.d/elixir.sh && mix --version), Bash(. /etc/profile.d/elixir.sh && /root/.mix/rebar3 --version), Read
---

Run the canonical Tau toolchain installer and verify it. The script is
idempotent — re-running on an already-installed sandbox is a no-op.

Steps:

1. Run the installer (root if available, plain bash otherwise):

   ```sh
   sudo bash scripts/install-toolchain.sh 2>/dev/null || bash scripts/install-toolchain.sh
   ```

2. Source the profile and verify:

   ```sh
   . /etc/profile.d/elixir.sh
   elixir --version
   mix --version
   /root/.mix/rebar3 --version
   ```

3. Report the installed versions to the user, plus the sandbox caveat:

   > Inside the Anthropic sandbox `mix deps.get` cannot reach hex.pm
   > because the egress proxy refuses Erlang's TLS handshake (502/503
   > on every HTTPS host). `mix compile` / `mix format` / `mix test`
   > work as long as `deps/` is already populated — typically by a
   > prior CI run.

If the script fails, read it (`Read scripts/install-toolchain.sh`) and
report the specific error to the user. Do NOT try to "fix" Erlang's
network access by setting `HEX_UNSAFE_HTTPS`, swapping mirrors, or
disabling TLS verification — those have all been tried and don't work.
The sandbox's egress policy is the blocker; see
`.claude/skills/tau-toolchain/SKILL.md` for the verified background.
