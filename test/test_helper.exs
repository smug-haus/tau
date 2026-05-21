# Excluded by default; opt-in with `--include` / `--only`:
#   :smoke      — Burrito binary smoke tests (need zig + xz to build the release)
#   :tui_smoke  — TUI PTY harness (needs tmux + a built binary)
#   :external   — coding-agent adapter tests that spawn real CLIs
#                 (`INTEGRATION=1 mix test --only external`).
ExUnit.start(exclude: [:smoke, :tui_smoke, :tui_ux, :external])
