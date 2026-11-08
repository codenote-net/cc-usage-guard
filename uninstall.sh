#!/bin/bash
# cc-usage-guard uninstaller
#
# Usage:
#   bash ~/.claude/usage-guard/uninstall.sh
#   curl -fsSL https://raw.githubusercontent.com/codenote-net/cc-usage-guard/main/uninstall.sh | bash
#
# What it does:
#   1. Backs up ~/.claude/settings.json to settings.json.bak-<timestamp>.
#   2. Removes the hook entries that point at guard-hook.sh. Other hooks are kept.
#   3. Restores the previous status line command (config.json "passthrough"),
#      or removes the statusLine setting when there was none.
#   4. Deletes ~/.claude/usage-guard/ (scripts, config and state files).
#
# Environment:
#   CLAUDE_CONFIG_DIR   Claude Code config directory (default: ~/.claude)

set -eu

CONFIG_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
SETTINGS_FILE="$CONFIG_DIR/settings.json"
GUARD_DIR="$CONFIG_DIR/usage-guard"
CONFIG_FILE="$GUARD_DIR/config.json"

info() { printf '%s\n' "$*"; }
fail() { printf 'cc-usage-guard: %s\n' "$*" >&2; exit 1; }

command -v jq >/dev/null 2>&1 || fail "jq is required but was not found."

passthrough=""
if [ -f "$CONFIG_FILE" ] && jq -e . "$CONFIG_FILE" >/dev/null 2>&1; then
  passthrough=$(jq -r '.passthrough // empty' "$CONFIG_FILE")
fi

if [ -f "$SETTINGS_FILE" ]; then
  jq -e . "$SETTINGS_FILE" >/dev/null 2>&1 || fail "$SETTINGS_FILE is not valid JSON. Fix it and run the uninstaller again."

  backup="$CONFIG_DIR/settings.json.bak-$(date +%Y%m%d%H%M%S)"
  cp "$SETTINGS_FILE" "$backup"
  info "Backed up settings to $backup"

  new_settings=$(jq \
    --arg passthrough "$passthrough" \
    '
    def ours: (.command // "") | test("usage-guard/guard-hook\\.sh");
    def strip_event($event):
      if (.hooks[$event]? | type) == "array" then
        .hooks[$event] |= map(select(any((.hooks // [])[]; ours) | not))
        | if (.hooks[$event] | length) == 0 then del(.hooks[$event]) else . end
      else . end;

    strip_event("PreToolUse")
    | strip_event("UserPromptSubmit")
    | if (.hooks | type) == "object" and (.hooks | length) == 0 then del(.hooks) else . end
    | if ((.statusLine.command // "") | test("usage-guard/statusline\\.sh")) then
        if $passthrough == "" then del(.statusLine)
        else .statusLine = ({type: "command", command: $passthrough}
                            + (if (.statusLine.padding? | type) == "number" then {padding: .statusLine.padding} else {} end))
        end
      else . end
    ' "$SETTINGS_FILE")

  tmp_settings="$SETTINGS_FILE.tmp.$$"
  printf '%s\n' "$new_settings" > "$tmp_settings"
  mv -f "$tmp_settings" "$SETTINGS_FILE"
  info "Removed cc-usage-guard hooks and status line from $SETTINGS_FILE"
  if [ -n "$passthrough" ]; then
    info "Restored previous status line command: $passthrough"
  fi
else
  info "No settings file at $SETTINGS_FILE; nothing to restore."
fi

if [ -d "$GUARD_DIR" ]; then
  rm -rf "$GUARD_DIR"
  info "Deleted $GUARD_DIR"
fi

info ""
info "cc-usage-guard has been uninstalled. Open a new 'claude' session for the change to take effect."
