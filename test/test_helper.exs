# Excluded by default; opt-in with `--include` / `--only`:
#   :smoke      — Burrito binary smoke tests (need zig + xz to build the release)
#   :tui_smoke  — TUI PTY harness (needs tmux + a built binary)
ExUnit.start(exclude: [:smoke, :tui_smoke])
