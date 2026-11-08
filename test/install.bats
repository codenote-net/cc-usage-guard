#!/usr/bin/env bats

load test_helper

setup() {
  common_setup
}

# --- install -----------------------------------------------------------------

@test "install: fails with instructions when jq is missing" {
  # Restrict PATH to a directory that only holds the stub `claude`.
  PATH="$BATS_TEST_TMPDIR/bin" run /bin/bash "$INSTALL"
  [ "$status" -ne 0 ]
  [[ "$output" == *"jq is required"* ]]
  [[ "$output" == *"brew install jq"* ]]
  [ ! -e "$GUARD_DIR" ]
}

@test "install: fails with instructions when claude is missing" {
  # PATH holds jq and the core utilities only, so a real `claude` on the host cannot leak in.
  mkdir -p "$BATS_TEST_TMPDIR/jqbin"
  ln -s "$(command -v jq)" "$BATS_TEST_TMPDIR/jqbin/jq"
  PATH="$BATS_TEST_TMPDIR/jqbin:/usr/bin:/bin" run /bin/bash "$INSTALL"
  [ "$status" -ne 0 ]
  [[ "$output" == *"claude (Claude Code CLI) was not found"* ]]
  [ ! -e "$GUARD_DIR" ]
}

@test "install: creates settings.json when none exists" {
  run /bin/bash "$INSTALL"
  [ "$status" -eq 0 ]
  [ -f "$SETTINGS" ]
  [ "$(jq -r .statusLine.type "$SETTINGS")" = "command" ]
  [ "$(jq -r .statusLine.command "$SETTINGS")" = "~/.claude/usage-guard/statusline.sh" ]
  [ "$(jq -r '.hooks.PreToolUse[0].matcher' "$SETTINGS")" = "*" ]
  [ "$(jq -r '.hooks.PreToolUse[0].hooks[0].command' "$SETTINGS")" = "~/.claude/usage-guard/guard-hook.sh" ]
  [ "$(jq -r '.hooks.PreToolUse[0].hooks[0].timeout' "$SETTINGS")" = "5" ]
  [ "$(jq -r '.hooks.UserPromptSubmit[0].hooks[0].command' "$SETTINGS")" = "~/.claude/usage-guard/guard-hook.sh" ]
  [ "$(jq -r '.hooks.UserPromptSubmit[0] | has("matcher")' "$SETTINGS")" = "false" ]
  [ "$(count_guard_hooks)" -eq 2 ]
}

@test "install: copies the scripts and makes them executable" {
  run /bin/bash "$INSTALL"
  [ "$status" -eq 0 ]
  [ -x "$GUARD_DIR/statusline.sh" ]
  [ -x "$GUARD_DIR/guard-hook.sh" ]
  [ -x "$GUARD_DIR/uninstall.sh" ]
  cmp -s "$GUARD_DIR/statusline.sh" "$REPO_ROOT/bin/statusline.sh"
  cmp -s "$GUARD_DIR/guard-hook.sh" "$REPO_ROOT/bin/guard-hook.sh"
  cmp -s "$GUARD_DIR/uninstall.sh" "$REPO_ROOT/uninstall.sh"
}

@test "install: writes config.json with defaults" {
  run /bin/bash "$INSTALL"
  [ "$status" -eq 0 ]
  [ "$(jq -c . "$CONFIG")" = '{"threshold":90,"max_age_seconds":3600,"passthrough":null,"windows":["five_hour","seven_day"]}' ]
}

@test "install: works on an empty settings object" {
  printf '{}\n' > "$SETTINGS"
  run /bin/bash "$INSTALL"
  [ "$status" -eq 0 ]
  [ "$(count_guard_hooks)" -eq 2 ]
  [ "$(jq -r .statusLine.command "$SETTINGS")" = "~/.claude/usage-guard/statusline.sh" ]
}

@test "install: backs up the existing settings.json" {
  printf '{"model": "opus"}\n' > "$SETTINGS"
  run /bin/bash "$INSTALL"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Backed up settings to"* ]]
  backups=("$CLAUDE_DIR"/settings.json.bak-*)
  [ "${#backups[@]}" -eq 1 ]
  [ "$(cat "${backups[0]}")" = '{"model": "opus"}' ]
}

@test "install: keeps unrelated settings untouched" {
  cat > "$SETTINGS" <<'EOF'
{"model": "opus", "permissions": {"allow": ["Bash(ls:*)"]}, "env": {"FOO": "bar"}}
EOF
  run /bin/bash "$INSTALL"
  [ "$status" -eq 0 ]
  [ "$(jq -r .model "$SETTINGS")" = "opus" ]
  [ "$(jq -r '.permissions.allow[0]' "$SETTINGS")" = "Bash(ls:*)" ]
  [ "$(jq -r .env.FOO "$SETTINGS")" = "bar" ]
}

@test "install: saves an existing statusLine command as passthrough and keeps padding" {
  cat > "$SETTINGS" <<'EOF'
{"statusLine": {"type": "command", "command": "~/bin/my-statusline.sh", "padding": 0}}
EOF
  run /bin/bash "$INSTALL"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Passthrough"* ]]
  [[ "$output" == *"~/bin/my-statusline.sh"* ]]
  [ "$(jq -r .passthrough "$CONFIG")" = "~/bin/my-statusline.sh" ]
  [ "$(jq -r .statusLine.command "$SETTINGS")" = "~/.claude/usage-guard/statusline.sh" ]
  [ "$(jq -r .statusLine.padding "$SETTINGS")" = "0" ]
}

@test "install: appends to existing hooks without removing them" {
  cat > "$SETTINGS" <<'EOF'
{"hooks": {
  "PreToolUse": [{"matcher": "Bash", "hooks": [{"type": "command", "command": "echo pre"}]}],
  "UserPromptSubmit": [{"hooks": [{"type": "command", "command": "echo prompt"}]}],
  "Stop": [{"hooks": [{"type": "command", "command": "echo stop"}]}]
}}
EOF
  run /bin/bash "$INSTALL"
  [ "$status" -eq 0 ]
  [ "$(jq '.hooks.PreToolUse | length' "$SETTINGS")" -eq 2 ]
  [ "$(jq -r '.hooks.PreToolUse[0].hooks[0].command' "$SETTINGS")" = "echo pre" ]
  [ "$(jq '.hooks.UserPromptSubmit | length' "$SETTINGS")" -eq 2 ]
  [ "$(jq -r '.hooks.UserPromptSubmit[0].hooks[0].command' "$SETTINGS")" = "echo prompt" ]
  [ "$(jq -r '.hooks.Stop[0].hooks[0].command' "$SETTINGS")" = "echo stop" ]
  [ "$(count_guard_hooks)" -eq 2 ]
}

@test "install: running twice does not duplicate entries or clobber passthrough" {
  cat > "$SETTINGS" <<'EOF'
{"statusLine": {"type": "command", "command": "echo original"}}
EOF
  run /bin/bash "$INSTALL"
  [ "$status" -eq 0 ]
  first=$(canon "$SETTINGS")

  run /bin/bash "$INSTALL"
  [ "$status" -eq 0 ]
  [ "$(canon "$SETTINGS")" = "$first" ]
  [ "$(count_guard_hooks)" -eq 2 ]
  [ "$(jq -r .passthrough "$CONFIG")" = "echo original" ]
}

@test "install: running twice preserves a customized config.json" {
  run /bin/bash "$INSTALL"
  [ "$status" -eq 0 ]
  jq '.threshold = 75 | .windows = ["five_hour"]' "$CONFIG" > "$CONFIG.new" && mv "$CONFIG.new" "$CONFIG"

  run /bin/bash "$INSTALL"
  [ "$status" -eq 0 ]
  [ "$(jq -r .threshold "$CONFIG")" = "75" ]
  [ "$(jq -c .windows "$CONFIG")" = '["five_hour"]' ]
  [[ "$output" == *"Threshold   : 75%"* ]]
}

@test "install: refuses to touch an invalid settings.json" {
  printf '{not json' > "$SETTINGS"
  run /bin/bash "$INSTALL"
  [ "$status" -ne 0 ]
  [[ "$output" == *"is not valid JSON"* ]]
  [ "$(cat "$SETTINGS")" = '{not json' ]
}

@test "install: honors CLAUDE_CONFIG_DIR and writes absolute paths outside HOME" {
  export CLAUDE_CONFIG_DIR="$BATS_TEST_TMPDIR/custom-config"
  mkdir -p "$CLAUDE_CONFIG_DIR"
  run /bin/bash "$INSTALL"
  [ "$status" -eq 0 ]
  [ -x "$CLAUDE_CONFIG_DIR/usage-guard/guard-hook.sh" ]
  [ "$(jq -r .statusLine.command "$CLAUDE_CONFIG_DIR/settings.json")" = "$CLAUDE_CONFIG_DIR/usage-guard/statusline.sh" ]
  [ ! -e "$SETTINGS" ]
}

@test "install: the installed scripts work end to end" {
  run /bin/bash "$INSTALL"
  [ "$status" -eq 0 ]

  run "$GUARD_DIR/statusline.sh" <<< '{"model":{"display_name":"M"},"rate_limits":{"five_hour":{"used_percentage":91,"resets_at":1794130000}}}'
  [ "$output" = "M | 5h:91%" ]

  run "$GUARD_DIR/guard-hook.sh" <<< '{}'
  [ "$status" -eq 0 ]
  [ "$(jq -r .continue <<< "$output")" = "false" ]
}

# --- uninstall ---------------------------------------------------------------

@test "uninstall: restores settings.json to its pre-install state" {
  cat > "$SETTINGS" <<'EOF'
{
  "model": "opus",
  "statusLine": {"type": "command", "command": "~/bin/my-statusline.sh", "padding": 1},
  "hooks": {
    "PreToolUse": [{"matcher": "Bash", "hooks": [{"type": "command", "command": "echo pre"}]}],
    "Stop": [{"hooks": [{"type": "command", "command": "echo stop"}]}]
  }
}
EOF
  before=$(canon "$SETTINGS")

  run /bin/bash "$INSTALL"
  [ "$status" -eq 0 ]
  [ "$(canon "$SETTINGS")" != "$before" ]

  run /bin/bash "$GUARD_DIR/uninstall.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Restored previous status line command: ~/bin/my-statusline.sh"* ]]
  [ "$(canon "$SETTINGS")" = "$before" ]
  [ ! -e "$GUARD_DIR" ]
}

@test "uninstall: removes statusLine and hooks when there were none before" {
  printf '{"model": "opus"}\n' > "$SETTINGS"
  before=$(canon "$SETTINGS")

  run /bin/bash "$INSTALL"
  [ "$status" -eq 0 ]
  run /bin/bash "$UNINSTALL"
  [ "$status" -eq 0 ]
  [ "$(canon "$SETTINGS")" = "$before" ]
  [ "$(jq 'has("hooks"), has("statusLine")' "$SETTINGS" | tr '\n' ' ')" = "false false " ]
}

@test "uninstall: leaves a foreign statusLine alone" {
  run /bin/bash "$INSTALL"
  [ "$status" -eq 0 ]
  # The user replaced the status line after installing.
  jq '.statusLine.command = "echo mine"' "$SETTINGS" > "$SETTINGS.new" && mv "$SETTINGS.new" "$SETTINGS"

  run /bin/bash "$UNINSTALL"
  [ "$status" -eq 0 ]
  [ "$(jq -r .statusLine.command "$SETTINGS")" = "echo mine" ]
  [ "$(count_guard_hooks)" -eq 0 ]
}

@test "uninstall: is safe to run when nothing is installed" {
  printf '{"model": "opus"}\n' > "$SETTINGS"
  before=$(canon "$SETTINGS")
  run /bin/bash "$UNINSTALL"
  [ "$status" -eq 0 ]
  [ "$(canon "$SETTINGS")" = "$before" ]
}

@test "uninstall: works without a settings.json" {
  run /bin/bash "$UNINSTALL"
  [ "$status" -eq 0 ]
  [[ "$output" == *"nothing to restore"* ]]
}

@test "uninstall: backs up settings.json before changing it" {
  printf '{}\n' > "$SETTINGS"
  run /bin/bash "$INSTALL"
  [ "$status" -eq 0 ]
  rm -f "$CLAUDE_DIR"/settings.json.bak-*
  sleep 1
  run /bin/bash "$UNINSTALL"
  [ "$status" -eq 0 ]
  backups=("$CLAUDE_DIR"/settings.json.bak-*)
  [ "${#backups[@]}" -eq 1 ]
  [ "$(jq -r .statusLine.command "${backups[0]}")" = "~/.claude/usage-guard/statusline.sh" ]
}
