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

### Changed
- Repo wiped of unrelated Clojure AoC2020 content.

### Notes
- Implementation milestones M1 — M8 are tracked in
  `/root/.claude/plans/clear-out-this-repo-fluffy-hamming.md`.
