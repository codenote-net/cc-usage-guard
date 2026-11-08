# cc-usage-guard

Stop your Claude Code sessions automatically when subscription usage reaches a
threshold (default 90%), so a long-running agent never burns through the last
slice of your 5-hour or 7-day quota while you are not watching.

Unofficial. Not affiliated with Anthropic.

```
Fable 5.1 | 5h:42.5% 7d:63%          <- status line while usage is below the threshold
```

```
cc-usage-guard: 5-hour window at 91% (resets 2026-11-08T09:26:40Z). Threshold is 90%.
Session stopped to preserve remaining quota. Wait for the reset, or raise the
threshold via CLAUDE_USAGE_GUARD_THRESHOLD or ~/.claude/usage-guard/config.json.
```

## How it works

Claude Code reports your subscription usage (`rate_limits`) to the status line
command on every refresh. cc-usage-guard turns that into a guard:

```
 Claude Code TUI
      |
      |  status line JSON (includes rate_limits.*.used_percentage)
      v
 statusline.sh  --writes-->  ~/.claude/usage-guard/usage.json
      |                               |
      |  "Fable 5.1 | 5h:42% 7d:63%"  |  read on every tool call / prompt
      v                               v
 status bar                    guard-hook.sh  (PreToolUse, UserPromptSubmit)
                                      |
                                      |  usage >= threshold?
                                      v
                        {"continue": false, "stopReason": "..."}
```

- **statusline.sh** records the `five_hour`, `seven_day` and `spend_limit`
  percentages plus their reset times, and shows them in the status bar. If you
  already had a status line, its command is kept and run first; the usage
  figures are appended to its output.
- **guard-hook.sh** runs before every tool call and every prompt you submit.
  When a monitored window has reached the threshold it returns
  `continue: false`, which stops the session with the reason shown above.

The hook fails open: if the state file is missing, older than one hour, or
unreadable, the session continues.

## Requirements

- Claude Code 2.1 or newer, logged in with a claude.ai **Pro, Max or Ultra**
  subscription. Claude Code sends `rate_limits` only for these plans, so Team
  and Enterprise plans are not supported.
- macOS or Linux, `bash` 3.2 or newer.
- [`jq`](https://jqlang.github.io/jq/) 1.6 or newer (`brew install jq`,
  `sudo apt-get install jq`).

## Install

```bash
curl -fsSL https://raw.githubusercontent.com/codenote-net/cc-usage-guard/main/install.sh | bash
```

Or from a checkout:

```bash
git clone https://github.com/codenote-net/cc-usage-guard.git
cd cc-usage-guard
./install.sh
```

The installer:

1. Checks that `jq` and `claude` are available.
2. Copies `statusline.sh`, `guard-hook.sh` and `uninstall.sh` into `~/.claude/usage-guard/`.
3. Backs up `~/.claude/settings.json` to `settings.json.bak-<timestamp>`.
4. Saves any existing `statusLine.command` as `passthrough` in `config.json`.
5. Registers the status line and the `PreToolUse` / `UserPromptSubmit` hooks.

Running it again is safe: nothing is duplicated and your `config.json` is kept.
Open a new `claude` session afterwards; running sessions do not reload settings.

To review the script before piping it to `bash`, open
[`install.sh`](install.sh).

## Configuration

Settings live in `~/.claude/usage-guard/config.json`. Environment variables
override the file, which is handy for a one-off session:

```bash
CLAUDE_USAGE_GUARD_THRESHOLD=95 claude
```

| Key               | Default                     | Environment variable           | Meaning                                                                 |
| ----------------- | --------------------------- | ------------------------------ | ----------------------------------------------------------------------- |
| `threshold`       | `90`                        | `CLAUDE_USAGE_GUARD_THRESHOLD` | Stop when any monitored window reaches this used percentage.            |
| `max_age_seconds` | `3600`                      | `CLAUDE_USAGE_GUARD_MAX_AGE`   | Ignore usage data older than this. Prevents stale data from blocking.   |
| `windows`         | `["five_hour","seven_day"]` | `CLAUDE_USAGE_GUARD_WINDOWS`   | Windows to check. `spend_limit` can be added. Comma-separated in the env var. |
| `passthrough`     | `null`                      |                                | Your previous status line command. Set by the installer.                |

Other environment variables:

| Variable                  | Meaning                                                              |
| ------------------------- | -------------------------------------------------------------------- |
| `CLAUDE_USAGE_GUARD_DIR`  | Use a different state/config directory.                              |
| `CLAUDE_USAGE_GUARD_DEBUG`| Set to `1` to save the raw status line JSON to `last-statusline.json`. |
| `CLAUDE_CONFIG_DIR`       | Honored like Claude Code does: settings and state go under this directory. |

## When the guard stops a session

The session ends with the `stopReason` shown above. To continue working:

- **Wait for the reset.** The reason includes the reset time of each window
  that is over the threshold.
- **Raise the threshold** for one session:
  `CLAUDE_USAGE_GUARD_THRESHOLD=100 claude`, or permanently by editing
  `threshold` in `config.json`.
- **Disable it** by running the uninstaller (see below).

## Known limitations

- Each window in `rate_limits` can be absent. Verified **Ultra** accounts have
  no 5-hour limit, so Claude Code sends only `seven_day` and the guard
  effectively watches the 7-day window alone. Pro and Max accounts receive
  both windows. `spend_limit` appears only behind a Claude apps gateway that
  sets a spend limit. The status line shows whichever windows are present.
- Usage is only recorded while an interactive terminal session (`claude`) is
  running, because only the status line receives `rate_limits`. Non-interactive
  runs (`claude -p`) and the desktop app do not update the state file. The
  hook ignores data older than `max_age_seconds`, so a stale file never blocks you.
- The guard acts before a tool call or when you submit a prompt. It cannot
  interrupt a single long model response that is already streaming.
- Claude Code itself still enforces the real limits; cc-usage-guard only stops
  earlier so that some quota is left for you.
- Team and Enterprise plans, Windows, Homebrew/npm packaging and a background
  refresher for idle sessions are out of scope for now.

## Uninstall

```bash
bash ~/.claude/usage-guard/uninstall.sh
```

or, without a local copy:

```bash
curl -fsSL https://raw.githubusercontent.com/codenote-net/cc-usage-guard/main/uninstall.sh | bash
```

The uninstaller removes only the hook entries and status line it added,
restores your previous status line command if there was one, backs up
`settings.json` first, and deletes `~/.claude/usage-guard/`.

## Development

```bash
git clone https://github.com/bats-core/bats-core.git /tmp/bats-core
shellcheck install.sh uninstall.sh bin/*.sh test/test_helper.bash
/tmp/bats-core/bin/bats test
```

Tests run against a throwaway `HOME`, so your real `~/.claude` is never touched.
CI runs ShellCheck and the test suite on Ubuntu and macOS (macOS uses the
system `bash` 3.2).

## License

[MIT](LICENSE)
