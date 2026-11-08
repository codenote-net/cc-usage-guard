#!/bin/bash
# Shared setup for the bats test suite.
#
# Every test runs against a throwaway HOME so the real ~/.claude is never touched.

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export REPO_ROOT
STATUSLINE="$REPO_ROOT/bin/statusline.sh"
GUARD_HOOK="$REPO_ROOT/bin/guard-hook.sh"
INSTALL="$REPO_ROOT/install.sh"
UNINSTALL="$REPO_ROOT/uninstall.sh"
export STATUSLINE GUARD_HOOK INSTALL UNINSTALL

common_setup() {
  export HOME="$BATS_TEST_TMPDIR/home"
  mkdir -p "$HOME/.claude"
  export CLAUDE_DIR="$HOME/.claude"
  export GUARD_DIR="$CLAUDE_DIR/usage-guard"
  export SETTINGS="$CLAUDE_DIR/settings.json"
  export CONFIG="$GUARD_DIR/config.json"
  export STATE="$GUARD_DIR/usage.json"

  unset CLAUDE_CONFIG_DIR
  unset CLAUDE_USAGE_GUARD_DIR
  unset CLAUDE_USAGE_GUARD_THRESHOLD
  unset CLAUDE_USAGE_GUARD_MAX_AGE
  unset CLAUDE_USAGE_GUARD_WINDOWS
  unset CLAUDE_USAGE_GUARD_DEBUG
  export TZ=UTC

  # A stub `claude` binary so the installer's prerequisite check passes in CI.
  mkdir -p "$BATS_TEST_TMPDIR/bin"
  printf '#!/bin/sh\necho stub\n' > "$BATS_TEST_TMPDIR/bin/claude"
  chmod +x "$BATS_TEST_TMPDIR/bin/claude"
  export PATH="$BATS_TEST_TMPDIR/bin:$PATH"
}

# write_state <five_hour|null> <seven_day|null> [spend_limit|null] [updated_at]
write_state() {
  local five="$1" week="$2" spend="${3:-null}" updated="${4:-$(date +%s)}"
  mkdir -p "$GUARD_DIR"
  cat > "$STATE" <<EOF
{"five_hour": $five, "seven_day": $week, "spend_limit": $spend,
 "resets_at": {"five_hour": 1794130000, "seven_day": 1794510000, "spend_limit": null},
 "updated_at": $updated}
EOF
}

# write_config '<json>'
write_config() {
  mkdir -p "$GUARD_DIR"
  printf '%s\n' "$1" > "$CONFIG"
}

# Canonical (sorted, pretty) JSON of a file for stable comparisons.
canon() {
  jq -S . "$1"
}

# Number of hook entries in settings.json whose command points at guard-hook.sh.
count_guard_hooks() {
  jq '[.hooks // {} | .[]? | .[]? | .hooks[]? | select(.command | test("usage-guard/guard-hook\\.sh"))] | length' "$SETTINGS"
}
