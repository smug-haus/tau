# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- M0: Mix project skeleton, supervision tree, telemetry handler attachments,
  empty `Tau.Settings.Cache` / `Tau.Permissions.RuleSet` publishing through
  to `:persistent_term`. Public API surface declared as stubs returning
  `{:error, :not_implemented}`.
- `CLAUDE.md` and `TAU.md` bootstrap files.
- Apache-2.0 license.
- GitHub Actions:
  - `ci.yml` — lint (format · credo · compile-warnings-as-errors),
    test matrix (Elixir 1.18.1/OTP 27.2 and 1.17.3/OTP 26.2), property
    suite, dialyzer with PLT cache, and an escript build sanity check.
  - `release.yml` — Burrito matrix (Linux x86_64/arm64, macOS Intel/Apple
    Silicon, Windows x86_64), `mix hex.publish`, ex_doc → gh-pages, and
    a GitHub Release that bundles all artefacts with SHA256SUMS.

### Changed
- Repo wiped of unrelated Clojure AoC2020 content.
- Reformatted `mix.exs`, `config/test.exs`, `lib/tau/registries.ex` to
  conform to `mix format` defaults.

### Notes
- Implementation milestones M1 — M8 are tracked in
  `/root/.claude/plans/clear-out-this-repo-fluffy-hamming.md`.
- Local toolchain: Erlang/OTP 25.3 (Ubuntu apt) + Elixir 1.17.3
  (precompiled OTP-25 build from elixir-lang releases). `mix deps.get`
  is blocked in the development sandbox (proxy interferes with Erlang
  httpc to `repo.hex.pm`); `mix format --check-formatted` and
  syntax-checks all pass locally. Full compile + tests will run on
  GitHub Actions.
