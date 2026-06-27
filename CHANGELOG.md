# Changelog

## 1.2

- macOS notifications when usage crosses 60% / 80% / 100% per metric
- Reset details now show relative time ("Resets in 4h 30m at 1:30pm …") for time-based windows, in addition to the existing relative-days style
- Metrics carry a stable `resetIdentifier` so the notifier can distinguish a new reset window from usage movement within the same window

## 1.1

- Stacked Claude Code + OpenAI Codex usage in one popover
- `Provider` abstraction holding all provider-specific CLI driving config, making additional CLIs pluggable without rewriting the flow
- Structured parsing of `/usage` and `/status` output into native metrics (percent used, reset times, credits) with raw terminal output as a fallback
- Caching with stale-while-revalidate and a 5-minute background refresh timer
- Timed-flow driving for Codex to work around ratatui's char-by-char cursor positioning
- Adaptive popover styling that follows the system appearance (light/dark)
- Per-provider header links to the web usage pages
- `build.sh` for building and relaunching without Xcode (Command Line Tools only)
- Parser tests

## 1.0.0

Initial release.

- Menu bar app with popover showing Claude Code usage
- Full ANSI color rendering via embedded PTY terminal
- Automatic `/usage` command execution
- Rate limit detection with friendly error screen
- Setup detection when Claude Code is not yet configured
- Click-to-dismiss popover
- Right-click to quit
- Runs as a lightweight menu bar agent (no Dock icon)
