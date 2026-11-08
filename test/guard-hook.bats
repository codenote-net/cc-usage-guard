#!/usr/bin/env bats

load test_helper

setup() {
  common_setup
}

run_hook() {
  run "$GUARD_HOOK" <<< '{"session_id":"test","hook_event_name":"PreToolUse","tool_name":"Bash"}'
}

@test "guard-hook: stays silent when usage is below the threshold" {
  write_state 50 40
  run_hook
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "guard-hook: stays silent just below the threshold" {
  write_state 89.9 10
  run_hook
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "guard-hook: stops the session when the 5-hour window reaches the threshold" {
  write_state 90 10
  run_hook
  [ "$status" -eq 0 ]
  [ "$(jq -r .continue <<< "$output")" = "false" ]
  reason=$(jq -r .stopReason <<< "$output")
  [[ "$reason" == *"5-hour window at 90%"* ]]
  [[ "$reason" == *"resets 2026-11-08T09:26:40Z"* ]]
  [[ "$reason" == *"Threshold is 90%"* ]]
  [[ "$reason" == *"CLAUDE_USAGE_GUARD_THRESHOLD"* ]]
}

@test "guard-hook: stops the session when the 7-day window exceeds the threshold" {
  write_state 10 95
  run_hook
  [ "$status" -eq 0 ]
  [ "$(jq -r .continue <<< "$output")" = "false" ]
  reason=$(jq -r .stopReason <<< "$output")
  [[ "$reason" == *"7-day window at 95%"* ]]
  [[ "$reason" == *"resets 2026-11-12T19:00:00Z"* ]]
  [[ "$reason" != *"5-hour"* ]]
}

@test "guard-hook: lists every window that is over the threshold" {
  write_state 92 91
  run_hook
  reason=$(jq -r .stopReason <<< "$output")
  [[ "$reason" == *"5-hour window at 92%"* ]]
  [[ "$reason" == *"7-day window at 91%"* ]]
}

@test "guard-hook: does nothing without a state file" {
  run_hook
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "guard-hook: ignores a stale state file" {
  write_state 99 99 null $(( $(date +%s) - 3601 ))
  run_hook
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "guard-hook: uses a fresh state file right at the age limit" {
  write_state 99 99 null $(( $(date +%s) - 3500 ))
  run_hook
  [ "$status" -eq 0 ]
  [ "$(jq -r .continue <<< "$output")" = "false" ]
}

@test "guard-hook: CLAUDE_USAGE_GUARD_MAX_AGE overrides the age limit" {
  write_state 99 99 null $(( $(date +%s) - 120 ))
  CLAUDE_USAGE_GUARD_MAX_AGE=60 run_hook
  [ -z "$output" ]

  CLAUDE_USAGE_GUARD_MAX_AGE=600 run_hook
  [ "$(jq -r .continue <<< "$output")" = "false" ]
}

@test "guard-hook: CLAUDE_USAGE_GUARD_THRESHOLD overrides the threshold" {
  write_state 50 40
  CLAUDE_USAGE_GUARD_THRESHOLD=45 run_hook
  [ "$status" -eq 0 ]
  reason=$(jq -r .stopReason <<< "$output")
  [[ "$reason" == *"5-hour window at 50%"* ]]
  [[ "$reason" == *"Threshold is 45%"* ]]
}

@test "guard-hook: threshold 0 always stops" {
  write_state 0 0
  CLAUDE_USAGE_GUARD_THRESHOLD=0 run_hook
  [ "$(jq -r .continue <<< "$output")" = "false" ]
}

@test "guard-hook: config.json threshold is used when no environment variable is set" {
  write_state 50 40
  write_config '{"threshold": 45}'
  run_hook
  [ "$(jq -r .continue <<< "$output")" = "false" ]
  [[ "$(jq -r .stopReason <<< "$output")" == *"Threshold is 45%"* ]]
}

@test "guard-hook: environment variable wins over config.json" {
  write_state 50 40
  write_config '{"threshold": 45}'
  CLAUDE_USAGE_GUARD_THRESHOLD=60 run_hook
  [ -z "$output" ]
}

@test "guard-hook: handles fractional usage percentages" {
  write_state 90.4 0
  CLAUDE_USAGE_GUARD_THRESHOLD=90.5 run_hook
  [ -z "$output" ]

  CLAUDE_USAGE_GUARD_THRESHOLD=90.3 run_hook
  [ "$(jq -r .continue <<< "$output")" = "false" ]
  [[ "$(jq -r .stopReason <<< "$output")" == *"5-hour window at 90.4%"* ]]
}

@test "guard-hook: ignores windows that have no value" {
  write_state null 10
  CLAUDE_USAGE_GUARD_THRESHOLD=5 run_hook
  reason=$(jq -r .stopReason <<< "$output")
  [[ "$reason" == *"7-day window at 10%"* ]]
  [[ "$reason" != *"5-hour"* ]]
}

@test "guard-hook: spend_limit is not checked by default" {
  write_state 10 10 99
  run_hook
  [ -z "$output" ]
}

@test "guard-hook: windows can be configured in config.json" {
  write_state 10 10 99
  write_config '{"windows": ["spend_limit"]}'
  run_hook
  [[ "$(jq -r .stopReason <<< "$output")" == *"spend limit window at 99%"* ]]
}

@test "guard-hook: CLAUDE_USAGE_GUARD_WINDOWS overrides the windows" {
  write_state 95 10
  CLAUDE_USAGE_GUARD_WINDOWS="seven_day" run_hook
  [ -z "$output" ]

  CLAUDE_USAGE_GUARD_WINDOWS="seven_day, five_hour" run_hook
  [[ "$(jq -r .stopReason <<< "$output")" == *"5-hour window at 95%"* ]]
}

@test "guard-hook: fails open on an invalid threshold value" {
  write_state 50 40
  CLAUDE_USAGE_GUARD_THRESHOLD=abc run_hook
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "guard-hook: fails open on a corrupt state file" {
  mkdir -p "$GUARD_DIR"
  printf 'not json' > "$STATE"
  CLAUDE_USAGE_GUARD_THRESHOLD=0 run_hook
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "guard-hook: fails open on a corrupt config file" {
  write_state 99 99
  write_config 'not json'
  run_hook
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "guard-hook: reports an unknown reset time when resets_at is missing" {
  mkdir -p "$GUARD_DIR"
  printf '{"five_hour": 95, "seven_day": 1, "updated_at": %s}\n' "$(date +%s)" > "$STATE"
  run_hook
  [[ "$(jq -r .stopReason <<< "$output")" == *"(resets unknown)"* ]]
}

@test "guard-hook: honors CLAUDE_USAGE_GUARD_DIR" {
  export CLAUDE_USAGE_GUARD_DIR="$BATS_TEST_TMPDIR/elsewhere"
  mkdir -p "$CLAUDE_USAGE_GUARD_DIR"
  printf '{"five_hour": 95, "seven_day": 1, "updated_at": %s}\n' "$(date +%s)" > "$CLAUDE_USAGE_GUARD_DIR/usage.json"
  run_hook
  [ "$(jq -r .continue <<< "$output")" = "false" ]
}

@test "guard-hook: output is a single line of valid JSON" {
  write_state 99 99
  run_hook
  [ "${#lines[@]}" -eq 1 ]
  jq -e . <<< "$output" >/dev/null
}
