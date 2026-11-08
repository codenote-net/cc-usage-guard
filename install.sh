#!/bin/bash
# cc-usage-guard installer
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/codenote-net/cc-usage-guard/main/install.sh | bash
#   ./install.sh            (from a checkout of the repository)
#
# What it does:
#   1. Checks that jq and claude are available.
#   2. Copies bin/statusline.sh, bin/guard-hook.sh and uninstall.sh into
#      ~/.claude/usage-guard/ (downloaded from GitHub when not run from a checkout).
#   3. Backs up ~/.claude/settings.json to settings.json.bak-<timestamp>.
#   4. Saves any existing statusLine command as "passthrough" in config.json.
#   5. Registers the status line and the PreToolUse / UserPromptSubmit hooks.
#      Re-running is safe: entries are never duplicated.
#
# Environment:
#   CLAUDE_CONFIG_DIR         Claude Code config directory (default: ~/.claude)
#   CLAUDE_USAGE_GUARD_REPO   GitHub repository to download from (default: codenote-net/cc-usage-guard)
#   CLAUDE_USAGE_GUARD_REF    Git ref to download (default: main)

set -eu

REPO="${CLAUDE_USAGE_GUARD_REPO:-codenote-net/cc-usage-guard}"
REF="${CLAUDE_USAGE_GUARD_REF:-main}"
RAW_BASE="https://raw.githubusercontent.com/$REPO/$REF"

CONFIG_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
SETTINGS_FILE="$CONFIG_DIR/settings.json"
GUARD_DIR="$CONFIG_DIR/usage-guard"
CONFIG_FILE="$GUARD_DIR/config.json"

# The command written to settings.json. Use "~" when the directory lives under
# $HOME so settings.json stays portable between machines.
case "$GUARD_DIR" in
  "$HOME"/*) GUARD_DIR_IN_SETTINGS="~${GUARD_DIR#"$HOME"}" ;;
  *) GUARD_DIR_IN_SETTINGS="$GUARD_DIR" ;;
esac
STATUSLINE_CMD="$GUARD_DIR_IN_SETTINGS/statusline.sh"
HOOK_CMD="$GUARD_DIR_IN_SETTINGS/guard-hook.sh"
HOOK_TIMEOUT=5

FILES="statusline.sh guard-hook.sh uninstall.sh"

info() { printf '%s\n' "$*"; }
fail() { printf 'cc-usage-guard: %s\n' "$*" >&2; exit 1; }

# --- 1. prerequisites ---------------------------------------------------------

if ! command -v jq >/dev/null 2>&1; then
  fail "jq is required but was not found.
  macOS:          brew install jq
  Debian/Ubuntu:  sudo apt-get install jq
  Fedora:         sudo dnf install jq
  Other:          https://jqlang.github.io/jq/download/"
fi

if ! command -v claude >/dev/null 2>&1; then
  fail "claude (Claude Code CLI) was not found on PATH.
  Install it first: https://docs.claude.com/en/docs/claude-code/setup"
fi

# --- 2. locate or download the scripts ---------------------------------------

script_dir=""
if [ -n "${BASH_SOURCE[0]:-}" ] && [ -f "${BASH_SOURCE[0]}" ]; then
  script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
fi

source_dir=""
tmp_dir=""
cleanup() { if [ -n "$tmp_dir" ]; then rm -rf "$tmp_dir"; fi; }
trap cleanup EXIT

if [ -n "$script_dir" ] && [ -f "$script_dir/bin/statusline.sh" ] && [ -f "$script_dir/bin/guard-hook.sh" ] && [ -f "$script_dir/uninstall.sh" ]; then
  source_dir="$script_dir"
else
  tmp_dir=$(mktemp -d "${TMPDIR:-/tmp}/cc-usage-guard.XXXXXX")
  mkdir -p "$tmp_dir/bin"
  info "Downloading cc-usage-guard ($REPO@$REF)..."
  for f in $FILES; do
    case "$f" in
      uninstall.sh) remote="$RAW_BASE/$f"; local_path="$tmp_dir/$f" ;;
      *)            remote="$RAW_BASE/bin/$f"; local_path="$tmp_dir/bin/$f" ;;
    esac
    if command -v curl >/dev/null 2>&1; then
      curl -fsSL "$remote" -o "$local_path" || fail "download failed: $remote"
    elif command -v wget >/dev/null 2>&1; then
      wget -q "$remote" -O "$local_path" || fail "download failed: $remote"
    else
      fail "curl or wget is required to download the scripts."
    fi
    [ -s "$local_path" ] || fail "downloaded file is empty: $remote"
  done
  source_dir="$tmp_dir"
fi

# --- 3. install files ---------------------------------------------------------

mkdir -p "$GUARD_DIR"
for f in $FILES; do
  case "$f" in
    uninstall.sh) src="$source_dir/$f" ;;
    *)            src="$source_dir/bin/$f" ;;
  esac
  cp "$src" "$GUARD_DIR/$f"
  chmod 755 "$GUARD_DIR/$f"
done

# --- 4. settings.json ---------------------------------------------------------

mkdir -p "$CONFIG_DIR"
if [ -f "$SETTINGS_FILE" ]; then
  jq -e . "$SETTINGS_FILE" >/dev/null 2>&1 || fail "$SETTINGS_FILE is not valid JSON. Fix it and run the installer again."
  backup="$CONFIG_DIR/settings.json.bak-$(date +%Y%m%d%H%M%S)"
  cp "$SETTINGS_FILE" "$backup"
  info "Backed up settings to $backup"
  settings=$(cat "$SETTINGS_FILE")
else
  settings='{}'
fi

# Existing status line command, unless it is already ours.
existing_cmd=$(printf '%s' "$settings" | jq -r '.statusLine.command // empty')
passthrough=""
case "$existing_cmd" in
  "") ;;
  *usage-guard/statusline.sh*) ;;
  *) passthrough="$existing_cmd" ;;
esac

new_settings=$(printf '%s' "$settings" | jq \
  --arg statusline_cmd "$STATUSLINE_CMD" \
  --arg hook_cmd "$HOOK_CMD" \
  --argjson timeout "$HOOK_TIMEOUT" \
  '
  def has_hook($event): any((.hooks[$event] // [])[]; any((.hooks // [])[]; (.command // "") | test("usage-guard/guard-hook\\.sh")));
  def hook_entry($with_matcher):
    (if $with_matcher then {matcher: "*"} else {} end)
    + {hooks: [{type: "command", command: $hook_cmd, timeout: $timeout}]};
  def add_hook($event; $with_matcher):
    if has_hook($event) then . else .hooks[$event] = ((.hooks[$event] // []) + [hook_entry($with_matcher)]) end;

  .statusLine = ({type: "command", command: $statusline_cmd}
                 + (if (.statusLine.padding? | type) == "number" then {padding: .statusLine.padding} else {} end))
  | .hooks = (.hooks // {})
  | add_hook("PreToolUse"; true)
  | add_hook("UserPromptSubmit"; false)
  ')

tmp_settings="$SETTINGS_FILE.tmp.$$"
printf '%s\n' "$new_settings" > "$tmp_settings"
mv -f "$tmp_settings" "$SETTINGS_FILE"

# --- 5. config.json -----------------------------------------------------------

existing_config='{}'
if [ -f "$CONFIG_FILE" ] && jq -e . "$CONFIG_FILE" >/dev/null 2>&1; then
  existing_config=$(cat "$CONFIG_FILE")
fi

new_config=$(printf '%s' "$existing_config" | jq \
  --arg passthrough "$passthrough" \
  '
  {threshold: 90, max_age_seconds: 3600, passthrough: null, windows: ["five_hour", "seven_day"]}
  + .
  + (if $passthrough == "" then {} else {passthrough: $passthrough} end)
  ')
tmp_config="$CONFIG_FILE.tmp.$$"
printf '%s\n' "$new_config" > "$tmp_config"
mv -f "$tmp_config" "$CONFIG_FILE"

# --- 6. done ------------------------------------------------------------------

threshold=$(printf '%s' "$new_config" | jq -r '.threshold')

info ""
info "cc-usage-guard installed to $GUARD_DIR"
info ""
info "  Status line : $STATUSLINE_CMD"
info "  Hooks       : PreToolUse, UserPromptSubmit -> $HOOK_CMD"
info "  Threshold   : ${threshold}% (edit \"threshold\" in $CONFIG_FILE,"
info "                or export CLAUDE_USAGE_GUARD_THRESHOLD=<percent>)"
if [ -n "$passthrough" ]; then
  info "  Passthrough : your previous status line command is kept and shown first:"
  info "                $passthrough"
fi
info ""
info "Open a new 'claude' session for the changes to take effect."
info "Uninstall with: bash $GUARD_DIR/uninstall.sh"
