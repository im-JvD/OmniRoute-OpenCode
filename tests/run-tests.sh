#!/usr/bin/env bash
# Test harness for omniroute-manager.sh (sandbox / isolated Docker testing).
#
# Simulates the target WSL2 environment:
#   - sanctioned network: registry-1.docker.io (docker.io refs) -> 403,
#     GHCR works, get.docker.com must never be touched
#   - no systemd (service shims), no Docker daemon (mock docker CLI that
#     launches a mock OmniRoute HTTP server implementing the real endpoint
#     contract of v3.8.51: /healthz, /api/auth/login, /api/providers/bulk,
#     /v1/models, /v1/chat/completions)
#   - Windows side: mock powershell.exe + wslpath with a username that
#     contains a SPACE ("Sepehr system")
#   - Node fallback mode: mock npm installs a fake `omniroute`/`pm2` backed
#     by the same mock server
#
# Usage: bash tests/run-tests.sh [T2 T3 ...]   (run all by default)
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(dirname "$HERE")"
SCRIPT="$ROOT/omniroute-manager.sh"
TESTROOT="${TESTROOT:-/tmp/omniroute-mgr-tests}"
PASS=0; FAIL=0; FAILED_NAMES=()

say()  { printf '%s\n' "$*"; }
ok()   { PASS=$((PASS+1)); say "  [PASS] $*"; }
bad()  { FAIL=$((FAIL+1)); FAILED_NAMES+=("$*"); say "  [FAIL] $*"; }

reset_state() {
  pkill -f "mock-omniroute/server.mjs" 2>/dev/null || true
  sleep 0.3
  rm -rf "$TESTROOT"
  mkdir -p "$TESTROOT/home" "$TESTROOT/mnt/c/Users/Sepehr system" "$TESTROOT/etc/docker"
}

common_env() {
  # Clear per-test knobs so they never leak across tests in the same run.
  unset OMNIRoute_NO_DOCKER_BUILD OMNIRoute_IMAGE_GHCR OMNIRoute_IMAGE_HUB
  unset OMNIRoute_GROQ_KEY OMNIRoute_OPENROUTER_KEY OMNIRoute_GEMINI_KEY
  unset OMNIRoute_CEREBRAS_KEY OMNIRoute_MISTRAL_KEY
  # Fake HOME keeps the sandbox clean and exercises the ~/ paths.
  export HOME="$TESTROOT/home"
  export MOCK_STATE="$TESTROOT/state"
  mkdir -p "$MOCK_STATE"
  # Windows-side simulation (username WITH a space).
  export MOCK_WIN_PROFILE='C:\Users\Sepehr system'
  export MOCK_WSL_MNT="$TESTROOT/mnt"
  export MOCK_BOOT_DELAY="${MOCK_BOOT_DELAY:-1}"
  export MOCK_CATALOG="$HERE/mock-omniroute/catalog.json"
  export MOCK_SERVER="$HERE/mock-omniroute/server.mjs"
  # Script overrides that keep the sandbox safe.
  export OMNIRoute_MNT_ROOT="$MOCK_WSL_MNT"
  export OMNIRoute_DAEMON_JSON="$TESTROOT/etc/docker/daemon.json"
  export OMNIRoute_LOG="$HOME/omniroute-install.log"
  export OMNIRoute_SRC_DIR="$HOME/omniroute"
  export OMNIRoute_DATA_DIR="$HOME/omniroute-data"
  export OMNIRoute_MASTER_KEY_FILE="$HOME/omniroute-master.key"
  export OMNIRoute_KEYS_FILE="$HOME/omniroute-keys.env"
  export OMNIRoute_SKIP_SWAP=1
}

run_mgr() {
  # Run the manager with a fresh TTY-less stdin (unless given).
  bash "$SCRIPT" "$@" < /dev/null 2>&1 | tee "$TESTROOT/last-run.log"
  return "${PIPESTATUS[0]}"
}

assert() { # assert <desc> <cmd...>
  local desc="$1"; shift
  if "$@" >/dev/null 2>&1; then ok "$desc"; else bad "$desc"; fi
}
assert_grep() { # assert_grep <desc> <pattern> <file>
  local desc="$1" pat="$2" file="$3"
  if grep -qE "$pat" "$file" 2>/dev/null; then ok "$desc"; else bad "$desc (pattern '$pat' not in $file)"; fi
}
assert_not_grep() {
  local desc="$1" pat="$2" file="$3"
  if grep -qE "$pat" "$file" 2>/dev/null; then bad "$desc (pattern '$pat' FOUND in $file)"; else ok "$desc"; fi
}

log="$TESTROOT/last-run.log"
CFG=""
mkcfg() { CFG="$MOCK_WSL_MNT/c/Users/Sepehr system/.config/opencode/opencode.json"; }

# ---------------------------------------------------------------------------
test_T1_syntax() {
  say "== T1: syntax check =="
  reset_state
  if bash -n "$SCRIPT"; then ok "bash -n clean"; else bad "bash -n clean"; fi
  if LC_ALL=C grep -nP '[^\x00-\x7F]' "$SCRIPT" >/dev/null 2>&1; then
    bad "script is ASCII-only (found non-ASCII chars: $(LC_ALL=C grep -nP '[^\x00-\x7F]' "$SCRIPT" | head -3 | tr '\n' '; '))"
  else
    ok "script is ASCII-only"
  fi
}

test_T2_install_e2e() {
  say "== T2: full install E2E (sanctions sim, GHCR pre-built, 3 of 5 keys) =="
  reset_state; common_env
  export PATH="$HERE/mock-bin:$PATH"
  export OMNIRoute_GROQ_KEY="gsk_test_groq_123"
  export OMNIRoute_GEMINI_KEY="AIza_test_gemini_123"
  export OMNIRoute_MISTRAL_KEY="mistral_test_123"
  local rc
  run_mgr --install; rc=$?
  mkcfg
  assert "install exited 0 (rc=$rc)" test "$rc" -eq 0
  assert_grep "6/6 verification tests passed" "Verification: 6/6 tests passed" "$log"
  assert "container running (mock state)" test -f "$MOCK_STATE/container"
  assert "daemon.json written with mirrors" grep -q "docker.arvancloud.ir" "$OMNIRoute_DAEMON_JSON"
  assert "daemon.json has buildkit feature" jq -e '.features.buildkit == true' "$OMNIRoute_DAEMON_JSON"
  assert "master key generated (sk-omni- prefix)" grep -qE '^sk-omni-[0-9a-f]{32}$' "$HOME/omniroute-master.key"
  assert "keys file saved mode 600" test "$(stat -c %a "$HOME/omniroute-keys.env")" = "600"
  assert "opencode.json written to Windows path (with space)" test -f "$CFG"
  assert "opencode.json is valid JSON" jq -e . "$CFG"
  assert "provider.omniroute.npm is @ai-sdk/openai-compatible" \
    test "$(jq -r '.provider.omniroute.npm' "$CFG")" = "@ai-sdk/openai-compatible"
  assert "baseURL points at dashboard port /v1" \
    test "$(jq -r '.provider.omniroute.options.baseURL' "$CFG")" = "http://127.0.0.1:20128/v1"
  assert "apiKey in config equals master key" \
    test "$(jq -r '.provider.omniroute.options.apiKey' "$CFG")" = "$(cat "$HOME/omniroute-master.key")"
  assert "model count == catalog size (12)" \
    test "$(jq '.provider.omniroute.models | length' "$CFG")" = "12"
  assert "every model has limit.context and limit.output" \
    test "$(jq '[.provider.omniroute.models[] | (.limit.context > 0) and (.limit.output > 0)] | all' "$CFG")" = "true"
  assert "default model picked from preferred list" \
    test "$(jq -r '.model' "$CFG")" = "omniroute/devstral-latest"
  assert "opencode.json has \$schema" test "$(jq -r '."$schema"' "$CFG")" = "https://opencode.ai/config.json"
  assert "context from catalog (devstral-latest 262144)" \
    test "$(jq -r '.provider.omniroute.models["devstral-latest"].limit.context' "$CFG")" = "262144"
  assert "3 provider connections registered" \
    test "$(jq 'length' "$MOCK_STATE/connections.json")" = "3"
  assert_not_grep "never contacted get.docker.com" "get.docker.com" "$MOCK_STATE/curl-urls.log"
  assert_not_grep "never contacted registry-1.docker.io" "registry-1.docker.io" "$MOCK_STATE/curl-urls.log"
  assert "pre-built image pulled from GHCR" grep -q "pull ghcr.io/diegosouzapw/omniroute:latest" "$MOCK_STATE/docker.log"
}

# Self-contained: reset, install once (default docker path).
fresh_install() {
  reset_state; common_env
  export PATH="$HERE/mock-bin:$PATH"
  export OMNIRoute_GROQ_KEY="${OMNIRoute_GROQ_KEY:-gsk_test}"
  run_mgr --install
  FRESH_RC=$?
}

test_T3_idempotent_rerun() {
  say "== T3: idempotent re-run (reuses keys, container, master key) =="
  fresh_install
  local before_key after_key
  before_key="$(cat "$HOME/omniroute-master.key" 2>/dev/null)"
  run_mgr --install; local rc=$?
  after_key="$(cat "$HOME/omniroute-master.key" 2>/dev/null)"
  mkcfg
  assert "re-run exited 0 (rc=$rc)" test "$rc" -eq 0
  assert "master key unchanged" test "$before_key" = "$after_key"
  assert_grep "container left up (env hash match)" "already running with current config" "$log"
  assert_grep "saved keys reused (non-TTY)" "reusing saved keys" "$log"
  assert "config still valid" jq -e . "$CFG"
  assert "config unchanged model count 12" \
    test "$(jq '.provider.omniroute.models | length' "$CFG")" = "12"
}

test_T4_master_key_rotation() {
  say "== T4: master key rotation triggers container recreation =="
  fresh_install
  echo "sk-omni-$(openssl rand -hex 16)" >"$HOME/omniroute-master.key"
  run_mgr --install; local rc=$?
  mkcfg
  assert "re-run after rotation exited 0 (rc=$rc)" test "$rc" -eq 0
  assert_grep "container recreated (hash mismatch)" "older config - recreating" "$log"
  assert "new master key propagated to opencode.json" \
    test "$(jq -r '.provider.omniroute.options.apiKey' "$CFG" 2>/dev/null)" = "$(cat "$HOME/omniroute-master.key" 2>/dev/null)"
}

test_T5_uninstall() {
  say "== T5: full uninstall (non-TTY --yes) =="
  fresh_install
  local cfg="$MOCK_WSL_MNT/c/Users/Sepehr system/.config/opencode/opencode.json"
  run_mgr --uninstall --yes; local rc=$?
  assert "uninstall exited 0 (rc=$rc)" test "$rc" -eq 0
  assert "container removed" test ! -f "$MOCK_STATE/container"
  assert "local image removed" test ! -f "$MOCK_STATE/img-omniroute-image_latest"
  assert "source dir removed" test ! -d "$HOME/omniroute"
  assert "data dir removed" test ! -d "$HOME/omniroute-data"
  assert "keys file removed" test ! -f "$HOME/omniroute-keys.env"
  assert "master key removed" test ! -f "$HOME/omniroute-master.key"
  assert "opencode.json deleted" test ! -f "$cfg"
  assert "mock server process stopped" bash -c '! curl -fsS --max-time 2 http://127.0.0.1:20128/healthz'
  assert_grep "uninstall logged" "uninstall finished" "$TESTROOT/home/omniroute-install.log"
}

test_T6_no_keys_abort() {
  say "== T6: no API keys -> clear abort =="
  reset_state; common_env
  export PATH="$HERE/mock-bin:$PATH"
  unset OMNIRoute_GROQ_KEY OMNIRoute_OPENROUTER_KEY OMNIRoute_GEMINI_KEY OMNIRoute_CEREBRAS_KEY OMNIRoute_MISTRAL_KEY 2>/dev/null || true
  run_mgr --install; local rc=$?
  assert "aborted non-zero (rc=$rc)" test "$rc" -ne 0
  assert_grep "clear error message" "At least ONE provider API key is required" "$log"
}

test_T7_non_tty_no_flags() {
  say "== T7: non-TTY without flags -> usage + exit 2 (no hang) =="
  reset_state; common_env
  export PATH="$HERE/mock-bin:$PATH"
  local out rc
  out="$(timeout 20 bash "$SCRIPT" < /dev/null 2>&1)"; rc=$?
  assert "exits with code 2 (rc=$rc)" test "$rc" -eq 2
  assert_grep "usage printed" "Non-TTY sessions must pass --install or --uninstall" <(printf '%s' "$out")
}

test_T8_source_build_fallback() {
  say "== T8: all pulls 403 -> shallow clone + BuildKit build (mocked build) =="
  reset_state; common_env
  export PATH="$HERE/mock-bin-build:$HERE/mock-bin:$PATH"
  # Point both registries at docker.io refs (mock returns 403 for docker.io/*).
  export OMNIRoute_IMAGE_GHCR="docker.io/omniroute-ghcr-proxy/omniroute"
  export OMNIRoute_IMAGE_HUB="diegosouzapw/omniroute"
  export OMNIRoute_GROQ_KEY="gsk_test"
  local rc
  run_mgr --install; rc=$?
  assert "install via build exited 0 (rc=$rc)" test "$rc" -eq 0
  assert_grep "shallow clone used" "shallow clone" "$log"
  assert_grep "BuildKit build invoked" "DOCKER_BUILDKIT=1" "$log"
  assert_grep "build memory cap applied" "Build resource caps" "$log"
  assert "source cloned to ~/omniroute" test -d "$HOME/omniroute"
  assert "built image tagged" test -f "$MOCK_STATE/img-omniroute-image_latest"
  assert "6/6 tests passed" grep -q "Verification: 6/6 tests passed" "$log"
  assert "403 sanction responses were received and handled" grep -q "403 Forbidden" "$MOCK_STATE/docker.log"
}

test_T9_node_mode_e2e() {
  say "== T9: non-Docker Node mode E2E (mock npm + pm2) =="
  reset_state; common_env
  export PATH="$HERE/mock-bin-node:$HERE/mock-bin:$MOCK_STATE/bin:$PATH"
  export OMNIRoute_NO_DOCKER_BUILD=1
  export OMNIRoute_GROQ_KEY="gsk_test"
  export OMNIRoute_MISTRAL_KEY="mistral_test"
  local rc
  run_mgr --install; rc=$?
  mkcfg
  assert "node-mode install exited 0 (rc=$rc)" test "$rc" -eq 0
  assert_grep "node mode selected" "Non-Docker mode: running OmniRoute directly" "$log"
  assert_grep "pm2 process started" "pm2" "$log"
  assert "pm2 reports omniroute online" \
    bash -c "pm2 jlist | jq -e '.[] | select(.name==\"omniroute\" and .pm2_env.status==\"online\")'"
  assert "opencode.json written" jq -e . "$CFG"
  assert "6/6 tests passed" grep -q "Verification: 6/6 tests passed" "$log"
  # uninstall node mode
  run_mgr --uninstall --yes; local rc2=$?
  assert "node-mode uninstall exited 0 (rc=$rc2)" test "$rc2" -eq 0
  assert "pm2 process deleted" bash -c '! pm2 jlist | jq -e ".[] | select(.name==\"omniroute\" and .pm2_env.status==\"online\")"'
  assert "launcher removed" test ! -f "$HOME/omniroute-run.sh"
  assert "server stopped" bash -c '! curl -fsS --max-time 2 http://127.0.0.1:20128/healthz'
}

test_T10_build_oom_node_fallback() {
  say "== T10: build OOM -> Node fallback path =="
  reset_state; common_env
  export PATH="$HERE/mock-bin-node:$HERE/mock-bin-build:$HERE/mock-bin:$MOCK_STATE/bin:$PATH"
  export OMNIRoute_IMAGE_GHCR="docker.io/omniroute-ghcr-proxy/omniroute"
  export OMNIRoute_IMAGE_HUB="diegosouzapw/omniroute"
  echo 1 >"$MOCK_STATE/force_build_oom"
  export OMNIRoute_GROQ_KEY="gsk_test"
  local rc
  run_mgr --install; rc=$?
  mkcfg
  assert "install exited 0 via node fallback (rc=$rc)" test "$rc" -eq 0
  assert_grep "build failure detected" "build failed" "$log"
  assert_grep "fell back to node mode" "Non-Docker mode: running OmniRoute directly" "$log"
  assert "6/6 tests passed" grep -q "Verification: 6/6 tests passed" "$log"
  run_mgr --uninstall --yes >/dev/null 2>&1 || true
}

test_T11_interactive_tty() {
  say "== T11: interactive TTY run (menu + 5 prompts, via pty) =="
  reset_state; common_env
  export PATH="$HERE/mock-bin:$PATH"
  unset OMNIRoute_GROQ_KEY OMNIRoute_OPENROUTER_KEY OMNIRoute_GEMINI_KEY OMNIRoute_CEREBRAS_KEY OMNIRoute_MISTRAL_KEY 2>/dev/null || true
  local rc=1
  if command -v script >/dev/null 2>&1; then
    printf '1\ngsk_tty_groq\n\nAIza_tty_gemini\n\ntty_mistral\n' | \
      timeout 120 script -qec "bash $SCRIPT" /dev/null >"$TESTROOT/tty.log" 2>&1
    rc=$?
    cp "$TESTROOT/home/omniroute-install.log" "$log" 2>/dev/null || true
  else
    bad "util-linux 'script' not available - TTY test skipped as FAIL"
  fi
  mkcfg
  assert "interactive install exited 0 (rc=$rc)" test "$rc" -eq 0
  assert_grep "menu option chosen" "Full Install" "$TESTROOT/tty.log" 2>/dev/null || true
  assert "opencode.json written" jq -e . "$CFG" 2>/dev/null || bad "opencode.json written"
  assert "6/6 tests passed" grep -q "Verification: 6/6 tests passed" "$log"
  # cleanup
  bash "$SCRIPT" --uninstall --yes < /dev/null >>"$TESTROOT/tty-uninstall.log" 2>&1 || true
}

test_T12_preserve_other_providers() {
  say "== T12: existing opencode.json with another provider is preserved =="
  reset_state; common_env
  export PATH="$HERE/mock-bin:$PATH"
  export OMNIRoute_GROQ_KEY="gsk_test"
  local udir="$MOCK_WSL_MNT/c/Users/Sepehr system/.config/opencode"
  mkdir -p "$udir"
  cat >"$udir/opencode.json" <<'EOF'
{
  "$schema": "https://opencode.ai/config.json",
  "provider": {
    "anthropic": {
      "npm": "@ai-sdk/anthropic",
      "options": { "apiKey": "sk-ant-other" },
      "models": { "claude-x": { "limit": { "context": 200000, "output": 8192 } } }
    }
  },
  "model": "anthropic/claude-x",
  "permission": { "edit": "allow" }
}
EOF
  local rc
  run_mgr --install; rc=$?
  assert "install with existing config exited 0 (rc=$rc)" test "$rc" -eq 0
  assert "anthropic provider preserved" \
    test "$(jq -r '.provider.anthropic.options.apiKey' "$udir/opencode.json")" = "sk-ant-other"
  assert "omniroute provider added" \
    test "$(jq -r '.provider.omniroute.npm' "$udir/opencode.json")" = "@ai-sdk/openai-compatible"
  assert "existing top-level model kept (not omniroute/)" \
    test "$(jq -r '.model' "$udir/opencode.json")" = "anthropic/claude-x"
  assert "unrelated top-level keys preserved" \
    test "$(jq -r '.permission.edit' "$udir/opencode.json")" = "allow"
  run_mgr --uninstall --yes >/dev/null 2>&1 || true
}

# ---------------------------------------------------------------------------
run_test() {
  case "$1" in
    T1) test_T1_syntax ;;
    T2) test_T2_install_e2e ;;
    T3) test_T3_idempotent_rerun ;;
    T4) test_T4_master_key_rotation ;;
    T5) test_T5_uninstall ;;
    T6) test_T6_no_keys_abort ;;
    T7) test_T7_non_tty_no_flags ;;
    T8) test_T8_source_build_fallback ;;
    T9) test_T9_node_mode_e2e ;;
    T10) test_T10_build_oom_node_fallback ;;
    T11) test_T11_interactive_tty ;;
    T12) test_T12_preserve_other_providers ;;
    *) say "unknown test $1" ;;
  esac
}

SELECTED="${*:-T1 T2 T3 T4 T5 T6 T7 T8 T9 T10 T11 T12}"
say "OmniRoute manager test harness"
say "Script: $SCRIPT"
say "Tests : $SELECTED"
say "----------------------------------------------------------------"

for t in $SELECTED; do
  run_test "$t"
done

say "----------------------------------------------------------------"
say "RESULT: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then
  say "Failed checks:"
  for f in "${FAILED_NAMES[@]}"; do say "  - $f"; done
  exit 1
fi
exit 0
