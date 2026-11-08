#!/bin/bash
# cc-usage-guard hook (PreToolUse / UserPromptSubmit)
#
# Reads the usage recorded by statusline.sh and stops the session when any
# monitored window has reached the threshold. The hook fails open: if the state
# file is missing, stale, or unreadable, the session continues untouched.
#
# Output on stop (stdout, exit 0):
#   {"continue": false, "stopReason": "..."}
#
# Requires: bash 3.2+, jq 1.6+
#
# Configuration (environment variables override config.json):
#   CLAUDE_USAGE_GUARD_THRESHOLD  Stop at this used percentage (default 90)
#   CLAUDE_USAGE_GUARD_MAX_AGE    Ignore state older than this many seconds (default 3600)
#   CLAUDE_USAGE_GUARD_WINDOWS    Comma-separated windows to check (default five_hour,seven_day)
#   CLAUDE_USAGE_GUARD_DIR        State/config directory (default: ~/.claude/usage-guard)

set -u

GUARD_DIR="${CLAUDE_USAGE_GUARD_DIR:-${CLAUDE_CONFIG_DIR:-$HOME/.claude}/usage-guard}"
CONFIG_FILE="$GUARD_DIR/config.json"
STATE_FILE="$GUARD_DIR/usage.json"

# The hook input is not needed; drain it so Claude Code never blocks on a full pipe.
cat > /dev/null

[ -f "$STATE_FILE" ] || exit 0
command -v jq >/dev/null 2>&1 || exit 0

config='{}'
if [ -f "$CONFIG_FILE" ]; then
  config=$(cat "$CONFIG_FILE" 2>/dev/null) || config='{}'
  [ -n "$config" ] || config='{}'
fi

now=$(date +%s)

# A single jq invocation performs the whole decision so the hook stays well
# within Claude Code's hook timeout. It prints nothing when the session may continue.
result=$(jq -r \
  --argjson now "$now" \
  --argjson config "$config" \
  --arg env_threshold "${CLAUDE_USAGE_GUARD_THRESHOLD:-}" \
  --arg env_max_age "${CLAUDE_USAGE_GUARD_MAX_AGE:-}" \
  --arg env_windows "${CLAUDE_USAGE_GUARD_WINDOWS:-}" \
  --arg config_path "$CONFIG_FILE" \
  '
  def num_or($fallback): (tonumber? // $fallback);
  def window_name: {five_hour: "5-hour", seven_day: "7-day", spend_limit: "spend limit"}[.] // .;
  def when: if . == null then "unknown" else (. | todate) end;

  ($config.threshold // 90 | num_or(90)) as $cfg_threshold
  | (if $env_threshold == "" then $cfg_threshold else ($env_threshold | num_or($cfg_threshold)) end) as $threshold
  | ($config.max_age_seconds // 3600 | num_or(3600)) as $cfg_max_age
  | (if $env_max_age == "" then $cfg_max_age else ($env_max_age | num_or($cfg_max_age)) end) as $max_age
  | (if $env_windows != "" then ($env_windows | split(",") | map(gsub("^\\s+|\\s+$"; "")) | map(select(. != "")))
     elif ($config.windows | type) == "array" then $config.windows
     else ["five_hour", "seven_day"] end) as $windows
  | . as $state
  | ($state.updated_at // 0 | num_or(0)) as $updated
  | if ($now - $updated) > $max_age then empty
    else
      [ $windows[]
        | . as $w
        | ($state[$w] | if type == "number" then . else null end) as $v
        | select($v != null and $v >= $threshold)
        | { window: $w, value: $v, resets_at: ($state.resets_at[$w]? // null) }
      ] as $over
      | if ($over | length) == 0 then empty
        else
          ($over | map((.window | window_name) + " window at " + (.value | tostring) + "% (resets " + (.resets_at | when) + ")") | join("; ")) as $detail
          | {
              continue: false,
              stopReason: ("cc-usage-guard: " + $detail + ". Threshold is " + ($threshold | tostring)
                + "%. Session stopped to preserve remaining quota. Wait for the reset, or raise the threshold via CLAUDE_USAGE_GUARD_THRESHOLD or " + $config_path + ".")
            }
          | tojson
        end
    end
  ' "$STATE_FILE" 2>/dev/null) || exit 0

if [ -n "$result" ]; then
  printf '%s\n' "$result"
fi
exit 0
