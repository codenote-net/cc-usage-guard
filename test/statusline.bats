#!/usr/bin/env bats

load test_helper

setup() {
  common_setup
}

FULL_INPUT='{"model":{"display_name":"Fable 5.1"},"rate_limits":{"five_hour":{"used_percentage":42.5,"resets_at":1794130000},"seven_day":{"used_percentage":5,"resets_at":1794510000}}}'
PARTIAL_INPUT='{"model":{"display_name":"Fable 5.1"},"rate_limits":{"seven_day":{"used_percentage":5,"resets_at":1794510000}}}'
NO_LIMITS_INPUT='{"model":{"display_name":"Fable 5.1"},"context_window":{"used_percentage":12}}'

@test "statusline: shows both windows and records the state file" {
  run "$STATUSLINE" <<< "$FULL_INPUT"
  [ "$status" -eq 0 ]
  [ "$output" = "Fable 5.1 | 5h:42.5% 7d:5%" ]

  [ -f "$STATE" ]
  [ "$(jq -r .five_hour "$STATE")" = "42.5" ]
  [ "$(jq -r .seven_day "$STATE")" = "5" ]
  [ "$(jq -r .spend_limit "$STATE")" = "null" ]
  [ "$(jq -r .resets_at.five_hour "$STATE")" = "1794130000" ]
  [ "$(jq -r .resets_at.seven_day "$STATE")" = "1794510000" ]

  now=$(date +%s)
  updated=$(jq -r .updated_at "$STATE")
  [ $((now - updated)) -ge 0 ]
  [ $((now - updated)) -lt 60 ]
}

@test "statusline: shows the spend limit when present" {
  input='{"model":{"display_name":"M"},"rate_limits":{"five_hour":{"used_percentage":10},"seven_day":{"used_percentage":20},"spend_limit":{"used_percentage":30}}}'
  run "$STATUSLINE" <<< "$input"
  [ "$status" -eq 0 ]
  [ "$output" = "M | 5h:10% 7d:20% spend:30%" ]
  [ "$(jq -r .spend_limit "$STATE")" = "30" ]
}

@test "statusline: records only the windows that are present" {
  run "$STATUSLINE" <<< "$PARTIAL_INPUT"
  [ "$status" -eq 0 ]
  [ "$output" = "Fable 5.1 | 7d:5%" ]
  [ "$(jq -r .five_hour "$STATE")" = "null" ]
  [ "$(jq -r .seven_day "$STATE")" = "5" ]
}

@test "statusline: prints usage: n/a and leaves the state file alone without rate_limits" {
  write_state 77 66 null 1700000000
  before=$(cat "$STATE")

  run "$STATUSLINE" <<< "$NO_LIMITS_INPUT"
  [ "$status" -eq 0 ]
  [ "$output" = "Fable 5.1 | usage: n/a" ]
  [ "$(cat "$STATE")" = "$before" ]
}

@test "statusline: does not create a state file without rate_limits" {
  run "$STATUSLINE" <<< "$NO_LIMITS_INPUT"
  [ "$status" -eq 0 ]
  [ ! -e "$STATE" ]
}

@test "statusline: works without a model name" {
  run "$STATUSLINE" <<< '{"rate_limits":{"five_hour":{"used_percentage":1}}}'
  [ "$status" -eq 0 ]
  [ "$output" = "5h:1%" ]
}

@test "statusline: survives invalid JSON input" {
  run "$STATUSLINE" <<< 'this is not json'
  [ "$status" -eq 0 ]
  [ "$output" = "usage: n/a" ]
  [ ! -e "$STATE" ]
}

@test "statusline: runs the passthrough command and appends usage" {
  write_config '{"passthrough": "jq -r .model.display_name | tr a-z A-Z"}'
  run "$STATUSLINE" <<< "$FULL_INPUT"
  [ "$status" -eq 0 ]
  [ "$output" = "FABLE 5.1 | 5h:42.5% 7d:5%" ]
  [ "$(jq -r .seven_day "$STATE")" = "5" ]
}

@test "statusline: passthrough receives the original JSON on stdin" {
  write_config '{"passthrough": "jq -c .rate_limits.seven_day"}'
  run "$STATUSLINE" <<< "$PARTIAL_INPUT"
  [ "$status" -eq 0 ]
  [ "$output" = '{"used_percentage":5,"resets_at":1794510000} | 7d:5%' ]
}

@test "statusline: passthrough with usage: n/a keeps the original output" {
  write_config '{"passthrough": "echo custom-line"}'
  run "$STATUSLINE" <<< "$NO_LIMITS_INPUT"
  [ "$status" -eq 0 ]
  [ "$output" = "custom-line | usage: n/a" ]
}

@test "statusline: falls back to the default display when the passthrough prints nothing" {
  write_config '{"passthrough": "true"}'
  run "$STATUSLINE" <<< "$FULL_INPUT"
  [ "$status" -eq 0 ]
  [ "$output" = "Fable 5.1 | 5h:42.5% 7d:5%" ]
}

@test "statusline: falls back to the default display when the passthrough fails" {
  write_config '{"passthrough": "exit 3"}'
  run "$STATUSLINE" <<< "$FULL_INPUT"
  [ "$status" -eq 0 ]
  [ "$output" = "Fable 5.1 | 5h:42.5% 7d:5%" ]
}

@test "statusline: saves the raw input only in debug mode" {
  run "$STATUSLINE" <<< "$FULL_INPUT"
  [ ! -e "$GUARD_DIR/last-statusline.json" ]

  CLAUDE_USAGE_GUARD_DEBUG=1 run "$STATUSLINE" <<< "$FULL_INPUT"
  [ "$status" -eq 0 ]
  [ -f "$GUARD_DIR/last-statusline.json" ]
  [ "$(jq -c . "$GUARD_DIR/last-statusline.json")" = "$(jq -c . <<< "$FULL_INPUT")" ]
}

@test "statusline: honors CLAUDE_USAGE_GUARD_DIR" {
  export CLAUDE_USAGE_GUARD_DIR="$BATS_TEST_TMPDIR/elsewhere"
  run "$STATUSLINE" <<< "$FULL_INPUT"
  [ "$status" -eq 0 ]
  [ -f "$CLAUDE_USAGE_GUARD_DIR/usage.json" ]
  [ ! -e "$STATE" ]
}

@test "statusline: honors CLAUDE_CONFIG_DIR" {
  export CLAUDE_CONFIG_DIR="$BATS_TEST_TMPDIR/custom-config"
  run "$STATUSLINE" <<< "$FULL_INPUT"
  [ "$status" -eq 0 ]
  [ -f "$CLAUDE_CONFIG_DIR/usage-guard/usage.json" ]
  [ ! -e "$STATE" ]
}

@test "statusline: leaves no temporary files behind" {
  run "$STATUSLINE" <<< "$FULL_INPUT"
  [ "$status" -eq 0 ]
  run find "$GUARD_DIR" -name 'usage.json.tmp*'
  [ -z "$output" ]
}
