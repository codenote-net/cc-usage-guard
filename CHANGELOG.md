# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.1.0] - 2026-11-08

### Added

- `bin/statusline.sh`: records `rate_limits` usage and reset times from the
  Claude Code status line into `~/.claude/usage-guard/usage.json` and shows
  `5h:xx% 7d:xx%` in the status bar. Delegates to a previously configured
  status line command when one is saved as `passthrough`.
- `bin/guard-hook.sh`: `PreToolUse` / `UserPromptSubmit` hook that returns
  `continue: false` when any monitored window has reached the threshold.
  Fails open on missing, stale or unreadable state.
- `install.sh`: idempotent installer that copies the scripts, backs up
  `settings.json`, preserves an existing status line as `passthrough`, and
  merges the status line and hook entries with `jq`.
- `uninstall.sh`: removes only the entries added by the installer, restores
  the previous status line, and deletes the install directory.
- Configuration via `config.json` (`threshold`, `max_age_seconds`, `windows`,
  `passthrough`) with `CLAUDE_USAGE_GUARD_*` environment variable overrides.
- bats-core test suite and GitHub Actions CI (ShellCheck, Ubuntu, macOS).

[Unreleased]: https://github.com/codenote-net/cc-usage-guard/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/codenote-net/cc-usage-guard/releases/tag/v0.1.0
