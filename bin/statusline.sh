#!/bin/bash
# cc-usage-guard status line
#
# Claude Code pipes its status line JSON to this script. The script records the
# subscription usage (rate_limits) into a state file that guard-hook.sh reads,
# and prints a short usage summary for the status bar.
#
# If a status line command was configured before cc-usage-guard was installed,
# its command is stored in config.json as "passthrough". That command is run
# with the same input and its output is shown first, followed by the usage.
#
# Requires: bash 3.2+, jq 1.6+
#
# Environment:
#   CLAUDE_USAGE_GUARD_DIR    State/config directory (default: ~/.claude/usage-guard)
#   CLAUDE_USAGE_GUARD_DEBUG  Set to 1 to save the raw input JSON for inspection

set -u

GUARD_DIR="${CLAUDE_USAGE_GUARD_DIR:-${CLAUDE_CONFIG_DIR:-$HOME/.claude}/usage-guard}"
CONFIG_FILE="$GUARD_DIR/config.json"
STATE_FILE="$GUARD_DIR/usage.json"
RAW_FILE="$GUARD_DIR/last-statusline.json"

input=$(cat)

if ! command -v jq >/dev/null 2>&1; then
  printf 'usage guard: jq not found\n'
  exit 0
fi

mkdir -p "$GUARD_DIR" 2>/dev/null || true

if [ "${CLAUDE_USAGE_GUARD_DEBUG:-0}" = "1" ]; then
  printf '%s' "$input" > "$RAW_FILE"
fi

# One jq call produces two lines:
#   1. the state document to persist (or an empty line when rate_limits is absent)
#   2. the usage summary to display
now=$(date +%s)
out=$(printf '%s' "$input" | jq -r --arg now "$now" '
  def pct($w): .rate_limits[$w].used_percentage? // null;
  def reset($w): .rate_limits[$w].resets_at? // null;
  def part($name; $v): if $v == null then empty else $name + ":" + ($v | tostring) + "%" end;
  (pct("five_hour")) as $five
  | (pct("seven_day")) as $week
  | (pct("spend_limit")) as $spend
  | (.model.display_name // "") as $model
  | (if ($five == null and $week == null and $spend == null) then ""
     else ({
       five_hour: $five,
       seven_day: $week,
       spend_limit: $spend,
       resets_at: {
         five_hour: reset("five_hour"),
         seven_day: reset("seven_day"),
         spend_limit: reset("spend_limit")
       },
       updated_at: ($now | tonumber)
     } | tojson)
     end),
    (if ($five == null and $week == null and $spend == null) then
       (if $model == "" then "usage: n/a" else $model + " | usage: n/a" end)
     else
       (if $model == "" then "" else $model + " | " end)
       + ([part("5h"; $five), part("7d"; $week), part("spend"; $spend)] | join(" "))
     end)
' 2>/dev/null)

if [ -z "$out" ]; then
  printf 'usage: n/a\n'
  exit 0
fi

state=${out%%$'\n'*}
summary=${out#*$'\n'}

if [ -n "$state" ]; then
  # Atomic update so guard-hook.sh never reads a partially written file.
  tmp="$STATE_FILE.tmp.$$"
  if printf '%s\n' "$state" > "$tmp" 2>/dev/null; then
    mv -f "$tmp" "$STATE_FILE" 2>/dev/null || rm -f "$tmp"
  fi
fi

# Delegate to the previously configured status line command, if any.
passthrough=""
if [ -f "$CONFIG_FILE" ]; then
  passthrough=$(jq -r '.passthrough // empty' "$CONFIG_FILE" 2>/dev/null)
fi

if [ -n "$passthrough" ]; then
  pt_out=$(printf '%s' "$input" | bash -c "$passthrough" 2>/dev/null)
  if [ -n "$pt_out" ]; then
    # Keep the original output and append the usage figures only.
    usage=${summary#*" | "}
    printf '%s | %s\n' "$pt_out" "$usage"
    exit 0
  fi
fi

printf '%s\n' "$summary"
