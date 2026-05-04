# Headless TUI smoke tests are integration-level (require tmux + a built
# Burrito binary) and not part of the default suite. Run with:
#   mix test --only tui_smoke
ExUnit.start(exclude: [:tui_smoke])
