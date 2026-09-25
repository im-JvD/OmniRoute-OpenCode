#!/usr/bin/env bash
# =============================================================================
#  omniroute-manager.sh
#  Production installer / uninstaller for OmniRoute + OpenCode integration
#
#  Target environment:
#    - Windows 10/11 + WSL2 (Ubuntu 22.04+)
#    - Iran / sanctioned networks: get.docker.com and registry-1.docker.io
#      return 403. This script NEVER calls get.docker.com. It installs Docker
#      from the Ubuntu apt repos and pulls images via GHCR first (GitHub is
#      reachable in Iran), falling back to Docker Hub through Iranian
#      registry mirrors (ArvanCloud / Liara / IranServer), then a source
#      build, then a pure-Node (non-Docker) mode.
#    - 8 GB RAM / 4-core machines: swap is provisioned if missing, Docker
#      builds get hard memory caps, and the pre-built image is preferred so
#      a build is only the fallback.
#    - Non-TTY friendly (MobaXterm, Windows Terminal, cron, CI): every
#      prompt has a timeout and a safe default; batch modes via flags.
#
#  Usage:
#    bash omniroute-manager.sh                # interactive menu (TTY only)
#    bash omniroute-manager.sh --install      # non-interactive install
#    bash omniroute-manager.sh --uninstall    # non-interactive uninstall
#                                             # (add --yes to confirm,
#                                             #  --remove-docker to also
#                                             #  purge Docker itself)
#    bash omniroute-manager.sh --help
#
#  API keys (all optional, at least one required) can be supplied:
#    - interactively (ENTER skips a provider), or
#    - via env vars in a non-TTY environment:
#        OMNIRoute_GROQ_KEY OMNIRoute_OPENROUTER_KEY OMNIRoute_GEMINI_KEY
#        OMNIRoute_CEREBRAS_KEY OMNIRoute_MISTRAL_KEY
#
#  Overridable settings (env vars):
#    OMNIRoute_PORT            dashboard+OpenAI-compatible port (default 20128)
#    OMNIRoute_API_PORT        secondary API port (default 20129)
#    OMNIRoute_BIND_HOST       host bind for the published ports (127.0.0.1)
#    OMNIRoute_SRC_DIR         source clone dir (default ~/omniroute)
#    OMNIRoute_DATA_DIR        persistent data dir (default ~/omniroute-data)
#    OMNIRoute_LOG             log file (default ~/omniroute-install.log)
#    OMNIRoute_MASTER_KEY_FILE master API key store (default ~/omniroute-master.key)
#    OMNIRoute_KEYS_FILE       provider key store  (default ~/omniroute-keys.env)
#    OMNIRoute_CONTAINER       container name (default omniroute-app)
#    OMNIRoute_IMAGE           local image name (default omniroute-image)
#    OMNIRoute_IMAGE_TAG       pre-built tag to try first (default latest)
#    OMNIRoute_IMAGE_TAG_PIN   pinned fallback tag (default 3.8.51)
#    OMNIRoute_NPM_REGISTRY    npm registry for non-Docker mode (default:
#                              npmjs.org, auto-fallback registry.npmmirror.com)
#    OMNIRoute_OPENCODE_DIR    where opencode.json is written (default:
#                              auto-detected Windows path via PowerShell)
#    OMNIRoute_SKIP_SWAP       set 1 to skip swap provisioning
#    OMNIRoute_ASSUME_DEPS=1   skip apt package installation (air-gapped)
#
#  What this script manages (uninstall removes exactly these):
#    - container  omniroute-app            (Docker mode)
#    - image      omniroute-image:latest   (Docker mode)
#    - pm2 proc   omniroute                (Node mode)
#    - $SRC_DIR   source clone             (build / Node-from-source mode)
#    - $DATA_DIR  SQLite data + logs
#    - $KEYS_FILE, $MASTER_KEY_FILE, $DATA_DIR/.env
#    - Windows   <userprofile>/.config/opencode/opencode.json (the omniroute
#                provider block; other providers are preserved)
#
#  Verified against OmniRoute release/v3.8.51 (2026-09):
#    - /v1/* OpenAI-compatible API is served on the DASHBOARD port (20128),
#      rewritten to /api/v1/* (next.config.mjs rewrites).
#    - /healthz is the lightweight liveness endpoint (Dockerfile HEALTHCHECK).
#    - Master proxy key: env OMNIROUTE_API_KEY accepted by /v1/* middleware
#      when REQUIRE_API_KEY=true (src/lib/db/apiKeys.ts).
#    - Provider API keys are NOT env vars (except gemini/gemini): they are
#      stored in the encrypted DB and are registered headlessly via the
#      dashboard management API (login with INITIAL_PASSWORD -> auth_token
#      cookie -> POST /api/providers/bulk, validateKeys=false).
#    - opencode.json schema: provider.omniroute.{name,npm,options,models},
#      every model REQUIRES limit.context AND limit.output (OpenCode v1
#      provider schema). This script generates it from the LIVE /v1/models
#      catalog, mirroring OmniRoute's own config generator.
#    - Official pre-built images: diegosouzapw/omniroute (Docker Hub) and
#      ghcr.io/diegosouzapw/omniroute (GHCR), tags latest + version + -web.
#      The -web variant (Chromium) is NOT used: API-key providers only need
#      the slim base image.
#
#  NOTE: output is intentionally ASCII-only English (terminal safety).
# =============================================================================

set -euo pipefail

# ---------------------------------------------------------------------------
# 0. Constants and overridable settings
# ---------------------------------------------------------------------------
readonly SCRIPT_VERSION="1.0.0"
readonly OMNIRoute_UPSTREAM_REPO="https://github.com/diegosouzapw/OmniRoute.git"
readonly OMNIRoute_UPSTREAM_BRANCH="release/v3.8.51"

OMNIRoute_PORT="${OMNIRoute_PORT:-20128}"
OMNIRoute_API_PORT="${OMNIRoute_API_PORT:-20129}"
OMNIRoute_BIND_HOST="${OMNIRoute_BIND_HOST:-127.0.0.1}"
SRC_DIR="${OMNIRoute_SRC_DIR:-$HOME/omniroute}"
DATA_DIR="${OMNIRoute_DATA_DIR:-$HOME/omniroute-data}"
LOG_FILE="${OMNIRoute_LOG:-$HOME/omniroute-install.log}"
MASTER_KEY_FILE="${OMNIRoute_MASTER_KEY_FILE:-$HOME/omniroute-master.key}"
KEYS_FILE="${OMNIRoute_KEYS_FILE:-$HOME/omniroute-keys.env}"
CONTAINER_NAME="${OMNIRoute_CONTAINER:-omniroute-app}"
IMAGE_NAME="${OMNIRoute_IMAGE:-omniroute-image}"
IMAGE_TAG="${OMNIRoute_IMAGE_TAG:-latest}"
IMAGE_TAG_PIN="${OMNIRoute_IMAGE_TAG_PIN:-3.8.51}"
IMAGE_GHCR="${OMNIRoute_IMAGE_GHCR:-ghcr.io/diegosouzapw/omniroute}"
IMAGE_HUB="${OMNIRoute_IMAGE_HUB:-diegosouzapw/omniroute}"
NPM_REGISTRY="${OMNIRoute_NPM_REGISTRY:-}"
DAEMON_JSON="${OMNIRoute_DAEMON_JSON:-/etc/docker/daemon.json}"
MNT_ROOT="${OMNIRoute_MNT_ROOT:-/mnt}"
NODE_MODE_PID_FILE="$HOME/.omniroute-node.pid"

# A registry that is blocked but looks alive can make `docker pull` hang
# for a very long time with zero output. Every pull therefore gets a hard
# timeout plus periodic heartbeat logs; OMNIRoute_PULL_TIMEOUT seconds.
PULL_TIMEOUT="${OMNIRoute_PULL_TIMEOUT:-900}"
# OMNIRoute_SKIP_PROBE=1 disables the pre-pull reachability probe (tests).
SKIP_PROBE="${OMNIRoute_SKIP_PROBE:-0}"

BASE_URL="http://127.0.0.1:${OMNIRoute_PORT}"

# Provider ids as known by OmniRoute (src/shared/constants/providers).
readonly PROVIDERS=(groq openrouter gemini cerebras mistral)

# Current free-tier models preferred for coding agents (2026-09 catalog).
# The first id that exists in the live /v1/models catalog becomes the default
# OpenCode model. Order = preference.
readonly PREFERRED_MODELS=(
  "devstral-latest"                        # Mistral free tier (code agent)
  "qwen/qwen3.8-27b"                       # Groq free tier (fast)
  "openai/gpt-oss-120b"                    # Groq free tier
  "gemini-2.5-flash"                       # Google AI free tier
  "codestral-latest"                       # Mistral free tier (alias->2508)
  "deepseek/deepseek-chat-v3-0324:free"    # OpenRouter free tier
  "zai-glm-4.7"                            # Cerebras (free trial quota)
  "llama-3.3-70b"                          # Cerebras
)

# Registry mirrors for sanctioned networks (per /etc/docker/daemon.json).
readonly MIRROR_LIST=(
  "https://docker.arvancloud.ir"
  "https://docker.hub.iran.liara.run"
  "https://docker.iranserver.com"
)

TMP_FILES=()
MODE=""            # install | uninstall
ASSUME_YES=0
REMOVE_DOCKER=0
RUN_MODE=""        # docker | node (resolved during install)

# ---------------------------------------------------------------------------
# 1. Logging (all output: ASCII English, mirrored to $LOG_FILE)
# ---------------------------------------------------------------------------
_log_init() {
  mkdir -p "$(dirname "$LOG_FILE")"
  touch "$LOG_FILE"
}

_log() {
  local level="$1"; shift
  local line
  line="$(date '+%Y-%m-%d %H:%M:%S') [$level] $*"
  echo "$line"
  echo "$line" >>"$LOG_FILE" 2>/dev/null || true
}

log()  { _log INFO  "$@"; }
warn() { _log WARN  "$@"; }
err()  { _log ERROR "$@"; }
die()  { err "$@"; exit 1; }

# Run a long command, teeing its output to console + log.
run_logged() {
  log "CMD: $*"
  local rc=0
  set +e
  "$@" 2>&1 | tee -a "$LOG_FILE"
  rc=${PIPESTATUS[0]}
  set -e
  [ "$rc" -eq 0 ] || return "$rc"
}

# Run a long command silently (output only to log).
run_quiet() {
  log "CMD: $*"
  local rc=0
  set +e
  "$@" >>"$LOG_FILE" 2>&1
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || return "$rc"
}

# ---------------------------------------------------------------------------
# 2. Error handling and cleanup
# ---------------------------------------------------------------------------
on_error() {
  local exit_code=$? line_no=$1
  err "Failed (exit $exit_code) near line $line_no."
  err "Last lines of the log:"
  tail -n 15 "$LOG_FILE" 2>/dev/null | sed 's/^/    /' || true
  err "Full log: $LOG_FILE"
  exit "$exit_code"
}
trap 'on_error $LINENO' ERR

cleanup_tmp() {
  local f
  for f in "${TMP_FILES[@]:-}"; do
    [ -n "$f" ] && rm -f "$f" 2>/dev/null || true
  done
}
trap cleanup_tmp EXIT
trap 'err "Interrupted by user."; exit 130' INT
trap 'err "Terminated."; exit 143' TERM

make_tmp() {
  local f
  f="$(mktemp "${TMPDIR:-/tmp}/omniroute-mgr.XXXXXX")"
  TMP_FILES+=("$f")
  echo "$f"
}

# ---------------------------------------------------------------------------
# 3. Small utilities
# ---------------------------------------------------------------------------
# Interactive-terminal detection. True when stdin is a TTY (the normal
# case), OR when the script is piped in (curl ... | bash) but a
# controlling terminal still exists for the user to type into. In the
# piped case stdin carries the script's own bytes, so prompts must read
# from /dev/tty instead of stdin.
# OMNIRoute_FORCE_NO_TTY=1 forces the non-TTY path (used by the test
# harness to simulate a terminal-less session deterministically).
is_tty() {
  [ -n "${OMNIRoute_FORCE_NO_TTY:-}" ] && return 1
  [ -t 0 ] && return 0
  [ -r /dev/tty ] && [ -w /dev/tty ]
}

# DC: run docker, escalating to sudo ONLY when the current user genuinely
# lacks socket access. A freshly installed WSL user joins the docker group
# only after re-login, so during THIS session the first docker call usually
# gets "permission denied ... docker.sock" and must be retried with sudo.
# We try the bare command first (covers root, docker-group members, and any
# rootless/mock daemon), and only escalate on a clear permission error - we
# never re-run a command that already succeeded or failed for another reason.
in_docker_group() { id -nG 2>/dev/null | tr ' ' '\n' | grep -qx docker; }
DC() {
  if [ "$(id -u)" -eq 0 ] || in_docker_group; then
    docker "$@"
    return $?
  fi
  local errfile rc=0
  errfile="$(make_tmp)"
  docker "$@" 2>"$errfile" || rc=$?
  if [ "$rc" -eq 0 ]; then
    rm -f "$errfile"
    return 0
  fi
  if [ -n "$SUDO" ] && grep -qiE "permission denied|operation not permitted|cannot connect|docker.sock" "$errfile" 2>/dev/null; then
    rm -f "$errfile"
    $SUDO docker "$@"
    return $?
  fi
  cat "$errfile" >&2 2>/dev/null || true
  rm -f "$errfile"
  return "$rc"
}

# SUDO="" when already root, else "sudo" (required for docker/swap/apt).
resolve_sudo() {
  if [ "$(id -u)" -eq 0 ]; then
    SUDO=""
  elif command -v sudo >/dev/null 2>&1; then
    SUDO="sudo"
  else
    SUDO=""
  fi
}

# systemd is only "active" when PID 1 is systemd (WSL2 can have the
# /run/systemd/system stub present while systemd is NOT running, e.g. Docker
# containers and plain WSL2). Never trust the directory alone.
systemd_active() {
  [ -d /run/systemd/system ] || return 1
  command -v systemctl >/dev/null 2>&1 || return 1
  [ "$(cat /proc/1/comm 2>/dev/null || echo none)" = "systemd" ]
}

# Start a service with systemctl when systemd is actually running (WSL2 with
# systemd enabled), otherwise the SysV `service` wrapper (plain WSL2).
svc_start() {
  local svc="$1"
  if systemd_active; then
    if run_logged systemctl start "$svc"; then
      return 0
    fi
    warn "systemctl start $svc failed - falling back to 'service'."
  fi
  if command -v service >/dev/null 2>&1; then
    run_logged service "$svc" start
  else
    die "Neither working systemctl nor service command available. Start '$svc' manually."
  fi
}

svc_active() {
  local svc="$1"
  if systemd_active; then
    systemctl is-active "$svc" >/dev/null 2>&1
  elif command -v service >/dev/null 2>&1; then
    service "$svc" status >/dev/null 2>&1
  else
    return 1
  fi
}

# Prompt with a timeout + default. The answer is returned in $REPLY_LINE
# (NOT via stdout - this function is safe to call from command substitution
# and from subshells). Non-TTY stdin: uses the env var $3 when set, else the
# default. NEVER blocks a non-TTY session: no read without a TTY.
# Piped script (curl ... | bash): the answer is read from /dev/tty, since
# stdin holds the script itself.
prompt_line() {
  local prompt="$1" default="${2:-}" var_name="${3:-}"
  local reply=""
  if is_tty; then
    if [ -t 0 ]; then
      # shellcheck disable=SC2162
      read -r -t 180 -p "$prompt [${default}]: " reply || reply="${default}"
    else
      # Piped in (curl ... | bash): take the answer from the controlling
      # terminal; read -p writes the prompt to stderr (the terminal).
      read -r -t 180 -p "$prompt [${default}]: " reply </dev/tty || reply="${default}"
    fi
    # Ctrl-D / timeout leaves reply empty -> default.
  elif [ -n "$var_name" ] && [ -n "${!var_name:-}" ]; then
    reply="${!var_name}"
    _log INFO "Non-TTY stdin: using env var ${var_name} for '$prompt'"
  else
    reply="$default"
    _log INFO "Non-TTY stdin: using default '${default}' for '$prompt'"
  fi
  REPLY_LINE="${reply:-$default}"
  [ -z "$REPLY_LINE" ] && REPLY_LINE="$default"
  return 0
}

prompt_yes_no() {
  local prompt="$1" default="$2"
  prompt_line "$prompt" "$default" ""
  case "$REPLY_LINE" in
    [Yy]|[Yy][Ee][Ss]) return 0 ;;
    *) return 1 ;;
  esac
}

# ---------------------------------------------------------------------------
# 4. Environment detection
# ---------------------------------------------------------------------------
detect_environment() {
  log "=== Environment ==="
  log "OS: $(. /etc/os-release 2>/dev/null && echo "$PRETTY_NAME" || echo unknown)"
  log "User: $(whoami) (uid $(id -u)), HOME=$HOME"
  log "RAM: $(( $(awk '/MemTotal/{print $2}' /proc/meminfo) / 1024 )) MB, CPUs: $(nproc)"
  TOTAL_RAM_MB=$(( $(awk '/MemTotal/{print $2}' /proc/meminfo) / 1024 ))
  if grep -qiE "microsoft|wsl" /proc/version 2>/dev/null; then
    IS_WSL=1
    log "Runtime: WSL2 detected ($(cat /proc/version | tr ' ' '\n' | grep -i 'microsoft' | head -n1))"
  else
    IS_WSL=0
    warn "Not running under WSL2. Continuing (Linux host), but the Windows-side"
    warn "opencode.json detection will fall back to the WSL home directory."
  fi
  if systemd_active; then
    log "Init: systemd active (systemctl available)"
  else
    log "Init: no running systemd (WSL default) - will use 'service'"
  fi
  resolve_sudo
  [ -n "$SUDO" ] && log "Privilege helper: sudo" || log "Privilege helper: none (root)"
  log "================================="
}

require_tools() {
  local missing=()
  local t
  for t in git curl jq openssl awk; do
    command -v "$t" >/dev/null 2>&1 || missing+=("$t")
  done
  if [ "${#missing[@]}" -gt 0 ]; then
    if [ "${OMNIRoute_ASSUME_DEPS:-0}" = "1" ]; then
      die "Missing required tools: ${missing[*]} (and OMNIRoute_ASSUME_DEPS=1 set)."
    fi
    log "Installing missing tools: ${missing[*]}"
    if [ -n "$SUDO" ] || [ "$(id -u)" -eq 0 ]; then
      $SUDO apt-get update -y >>"$LOG_FILE" 2>&1 || warn "apt-get update failed - trying cached package lists"
      DEBIAN_FRONTEND=noninteractive run_logged \
        $SUDO apt-get install -y --no-install-recommends git curl jq openssl ca-certificates
    else
      die "Missing tools: ${missing[*]}. Install them with apt and re-run."
    fi
  else
    log "All required base tools present."
  fi
}

# Provision a swapfile when the machine has little RAM and no swap at all.
# WSL2 has no swap by default; an 8 GB box building OmniRoute will OOM
# without one. Only runs when swap is 0 and RAM < 12 GB.
ensure_swap() {
  [ "${OMNIRoute_SKIP_SWAP:-0}" = "1" ] && { log "Swap provisioning skipped (OMNIRoute_SKIP_SWAP=1)."; return 0; }
  [ "$(id -u)" -eq 0 ] || [ -n "$SUDO" ] || { warn "Not root and no sudo: cannot provision swap."; return 0; }
  local swap_kb
  swap_kb="$(awk '/SwapTotal/{print $2}' /proc/meminfo)"
  if [ "$swap_kb" -gt 0 ]; then
    log "Swap already present: $(( swap_kb / 1024 )) MB. Skipping."
    return 0
  fi
  if [ "$TOTAL_RAM_MB" -ge 12288 ]; then
    log "RAM >= 12 GB - skipping swap provisioning."
    return 0
  fi
  log "No swap detected on a $(( TOTAL_RAM_MB / 1024 )) GB host - creating a 4 GB swapfile"
  log "(required to survive the OmniRoute build without OOM)."
  local swapfile="/swapfile.omniroute"
  if $SUDO fallocate -l 4G "$swapfile" 2>>"$LOG_FILE" || $SUDO dd if=/dev/zero of="$swapfile" bs=1M count=4096 status=none 2>>"$LOG_FILE"; then
    $SUDO chmod 600 "$swapfile"
    $SUDO mkswap "$swapfile" >>"$LOG_FILE" 2>&1
    $SUDO swapon "$swapfile" 2>>"$LOG_FILE" && \
      log "Swap enabled: $swapfile (4 GB). Note: this is a host resource - the uninstaller does not remove it."
  else
    warn "Could not create swapfile (disk full or unsupported FS). Builds may OOM."
  fi
}

# ---------------------------------------------------------------------------
# 5. Docker installation (sanction-safe) + registry mirrors
# ---------------------------------------------------------------------------
install_docker_if_missing() {
  if command -v docker >/dev/null 2>&1; then
    log "Docker already installed: $(docker --version 2>/dev/null | head -n1)"
    return 0
  fi
  log "Docker not found. Installing docker.io from Ubuntu repositories."
  warn "Intentionally NOT using https://get.docker.com (403 in Iran)."
  if [ "$(id -u)" -ne 0 ] && [ -z "$SUDO" ]; then
    die "Docker is not installed and sudo is unavailable. Run this script with sudo access."
  fi
  DEBIAN_FRONTEND=noninteractive run_logged \
    $SUDO apt-get install -y --no-install-recommends docker.io
  log "Adding current user to the docker group (takes effect on next login;"
  log "this run continues via sudo)."
  $SUDO usermod -aG docker "$(whoami)" 2>>"$LOG_FILE" || true
}

configure_docker_mirrors() {
  log "Configuring $DAEMON_JSON (Iranian registry mirrors + BuildKit)."
  local daemon_json="$DAEMON_JSON"
  $SUDO mkdir -p "$(dirname "$daemon_json")"

  local mirrors_json existing_json
  mirrors_json="$(printf '%s\n' "${MIRROR_LIST[@]}" | jq -R . | jq -s .)"
  existing_json="{}"
  if [ -f "$daemon_json" ]; then
    if jq . "$daemon_json" >/dev/null 2>&1; then
      existing_json="$(cat "$daemon_json")"
    else
      local backup="${daemon_json}.bak-$(date +%Y%m%d%H%M%S)"
      warn "Existing daemon.json is not valid JSON - backing up to $backup"
      $SUDO cp "$daemon_json" "$backup"
      existing_json="{}"
    fi
  fi

  # Merge: keep existing settings, override mirrors + ensure buildkit feature.
  local new_json tmp
  new_json="$(jq -n \
    --argjson existing "$existing_json" \
    --argjson mirrors "$mirrors_json" \
    '($existing * {"registry-mirrors": $mirrors, "features": ((($existing.features // {}) * {"buildkit": true}))})')"

  # Write as the current user, then move into place (root moves files, it
  # does not need to write file contents - some sandboxes deny that).
  tmp="$(make_tmp)"
  printf '%s\n' "$new_json" >"$tmp"
  chmod 644 "$tmp"
  $SUDO mv -f "$tmp" "$daemon_json"
  $SUDO chown root:root "$daemon_json" 2>/dev/null || true
  $SUDO chmod 644 "$daemon_json" 2>/dev/null || true
  log "daemon.json updated:"
  $SUDO cat "$daemon_json" | sed 's/^/    /'

  restart_docker_daemon
}

# Restart the Docker daemon (mirrors only apply after a restart).
restart_docker_daemon() {
  log "Restarting Docker daemon to apply registry mirrors."
  if systemd_active; then
    if run_logged $SUDO systemctl restart docker; then
      return 0
    fi
    warn "systemctl restart docker failed - falling back to 'service'."
  fi
  if command -v service >/dev/null 2>&1; then
    if run_logged $SUDO service docker restart; then
      return 0
    fi
    warn "service restart failed - stopping then starting."
  fi
  $SUDO service docker stop >>"$LOG_FILE" 2>&1 || true
  svc_start docker
}

ensure_docker_running() {
  if run_quiet DC info; then
    log "Docker daemon is running."
    return 0
  fi
  log "Docker daemon not running - starting it."
  svc_start docker
  local i
  for i in $(seq 1 20); do
    if run_quiet DC info; then
      log "Docker daemon is up."
      return 0
    fi
    sleep 2
  done
  die "Docker daemon failed to start. Check: $SUDO journalctl -u docker OR: $SUDO service docker status"
}

# ---------------------------------------------------------------------------
# 6. API key collection (5 optional providers, >=1 required)
# ---------------------------------------------------------------------------
# Load saved keys from $KEYS_FILE into the KEY_* globals used by later steps.
apply_saved_keys() {
  # shellcheck disable=SC1090
  . "$KEYS_FILE"
  KEY_GROQ="${GROQ_KEY:-}"; KEY_OPENROUTER="${OPENROUTER_KEY:-}"
  KEY_GEMINI="${GEMINI_KEY:-}"; KEY_CEREBRAS="${CEREBRAS_KEY:-}"; KEY_MISTRAL="${MISTRAL_KEY:-}"
}

collect_keys() {
  log "=== API keys (press ENTER to skip a provider) ==="
  local groq_key="" openrouter_key="" gemini_key="" cerebras_key="" mistral_key=""

  if [ -f "$KEYS_FILE" ]; then
    if is_tty; then
      if prompt_yes_no "Saved keys found in $KEYS_FILE. Reuse them? (recommended on re-runs)" "y"; then
        apply_saved_keys
        log "Reusing saved keys."
        return 0
      fi
      log "Fresh entry requested - previous saved values will be replaced."
    else
      log "Non-TTY: reusing saved keys from $KEYS_FILE."
      apply_saved_keys
      return 0
    fi
  fi

  prompt_line "  Groq key (gsk_...) - console.groq.com" "" "OMNIRoute_GROQ_KEY"; groq_key="$REPLY_LINE"
  prompt_line "  OpenRouter key (sk-or-...) - openrouter.ai" "" "OMNIRoute_OPENROUTER_KEY"; openrouter_key="$REPLY_LINE"
  prompt_line "  Google AI key (AIza...) - aistudio.google.com" "" "OMNIRoute_GEMINI_KEY"; gemini_key="$REPLY_LINE"
  prompt_line "  Cerebras key - cloud.cerebras.ai" "" "OMNIRoute_CEREBRAS_KEY"; cerebras_key="$REPLY_LINE"
  prompt_line "  Mistral key - console.mistral.ai" "" "OMNIRoute_MISTRAL_KEY"; mistral_key="$REPLY_LINE"

  local count=0
  [ -n "$groq_key" ] && count=$((count+1))
  [ -n "$openrouter_key" ] && count=$((count+1))
  [ -n "$gemini_key" ] && count=$((count+1))
  [ -n "$cerebras_key" ] && count=$((count+1))
  [ -n "$mistral_key" ] && count=$((count+1))

  if [ "$count" -lt 1 ]; then
    die "At least ONE provider API key is required. Re-run and provide at least one (env vars work in non-TTY mode: OMNIRoute_GROQ_KEY etc.)."
  fi

  local tmp
  tmp="$(make_tmp)"
  {
    echo "# Provider API keys for OmniRoute (managed by omniroute-manager.sh)"
    echo "GROQ_KEY=\"$groq_key\""
    echo "OPENROUTER_KEY=\"$openrouter_key\""
    echo "GEMINI_KEY=\"$gemini_key\""
    echo "CEREBRAS_KEY=\"$cerebras_key\""
    echo "MISTRAL_KEY=\"$mistral_key\""
  } >"$tmp"
  mv "$tmp" "$KEYS_FILE"
  chmod 600 "$KEYS_FILE"
  log "Saved $count provider key(s) to $KEYS_FILE (mode 600)."

  # Expose to later steps.
  KEY_GROQ="$groq_key"; KEY_OPENROUTER="$openrouter_key"
  KEY_GEMINI="$gemini_key"; KEY_CEREBRAS="$cerebras_key"; KEY_MISTRAL="$mistral_key"
  log "================================================="
}

# ---------------------------------------------------------------------------
# 7. OmniRoute image acquisition: pre-built (GHCR -> Hub) -> build -> node
# ---------------------------------------------------------------------------
# A registry answering 200/401 to its /v2/ endpoint is reachable (401 =
# "unauthorized, present a token" = the server IS responding). Anything
# else (000, timeout, TLS failure) = network-level block.
registry_reachable() {
  local url="$1" code
  code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "$url" 2>/dev/null)" || code=000
  case "$code" in
    200|401) return 0 ;;
    *) return 1 ;;
  esac
}

image_pull_attempt() {
  local ref="$1"

  # GHCR refs cannot use the daemon.json mirrors (mirrors only cover
  # Docker Hub), so probe first: in many sanctioned networks github.com is
  # open while ghcr.io is blocked/throttled, and a blind pull would sit
  # there looking dead. Docker Hub refs are always attempted, because the
  # daemon transparently falls back to the configured mirrors.
  case "$ref" in
    ghcr.io/*)
      if [ "$SKIP_PROBE" != "1" ]; then
        if registry_reachable "https://ghcr.io/v2/"; then
          log "ghcr.io is reachable - attempting pull."
        else
          warn "ghcr.io not reachable from this network (probe failed)."
          warn "Skipping $ref - there is no mirror fallback for GHCR."
          return 1
        fi
      fi
      ;;
  esac

  log "Trying to pull pre-built image: $ref (timeout: ${PULL_TIMEOUT}s)"
  local out rc=0 waited=0
  out="$(make_tmp)"
  ( DC pull "$ref" >"$out" 2>&1 ) &
  local pull_pid=$!

  # Heartbeat + hard timeout: a slow-but-alive pull must never look hung.
  while kill -0 "$pull_pid" 2>/dev/null; do
    if [ "$waited" -ge "$PULL_TIMEOUT" ]; then
      log "Pull timed out after ${PULL_TIMEOUT}s - cancelling (daemon aborts the transfer)."
      kill "$pull_pid" 2>/dev/null || true
      break
    fi
    sleep 5
    waited=$((waited+5))
    if [ $((waited % 30)) -eq 0 ]; then
      log "Pull of $ref still in progress (${waited}s elapsed) - still waiting..."
    fi
  done
  wait "$pull_pid" 2>/dev/null || rc=$?
  # Surface the docker client output (progress lines / error) in the log.
  [ -s "$out" ] && cat "$out" >>"$LOG_FILE" 2>/dev/null || true

  if [ "$rc" -eq 0 ]; then
    run_quiet DC tag "$ref" "${IMAGE_NAME}:latest"
    log "Pulled and tagged as ${IMAGE_NAME}:latest"
    PREBUILT_REF="$ref"
    return 0
  fi
  warn "Pull failed for $ref (rc=$rc) - timeout, sanctions 403, or registry error."
  warn "For Docker Hub refs the daemon transparently uses the mirrors from daemon.json."
  return 1
}

acquire_image_docker() {
  log "=== Acquiring OmniRoute image (pre-built first: no local build) ==="
  local refs=(
    "${IMAGE_GHCR}:${IMAGE_TAG}"
    "${IMAGE_HUB}:${IMAGE_TAG}"
    "${IMAGE_GHCR}:${IMAGE_TAG_PIN}"
    "${IMAGE_HUB}:${IMAGE_TAG_PIN}"
  )
  local r
  for r in "${refs[@]}"; do
    if image_pull_attempt "$r"; then
      RUN_MODE="docker"
      return 0
    fi
  done
  warn "All pre-built image pulls failed. Falling back to a local Docker build."
  return 1
}

clone_source() {
  if [ -d "$SRC_DIR/.git" ]; then
    log "Source already cloned at $SRC_DIR - reusing (shallow)."
    return 0
  fi
  log "Cloning ${OMNIRoute_UPSTREAM_REPO} (branch ${OMNIRoute_UPSTREAM_BRANCH}, --depth 1)."
  warn "The repo is large (~1 GB). A shallow clone avoids the full history."
  rm -rf "$SRC_DIR"
  # GIT_TERMINAL_PROMPT=0: never hang waiting for credentials in non-TTY mode.
  run_logged env GIT_TERMINAL_PROMPT=0 GIT_LFS_SKIP_SMUDGE=1 git clone \
    --depth 1 --branch "$OMNIRoute_UPSTREAM_BRANCH" \
    "$OMNIRoute_UPSTREAM_REPO" "$SRC_DIR"
}

free_disk_mb() {
  # $1 = a path that may not exist yet (the clone target); walk up to the
  # nearest existing ancestor before asking df.
  local target="${1:-$SRC_DIR}"
  while [ ! -d "$target" ] && [ "$target" != "/" ]; do
    target="$(dirname "$target")"
  done
  df -BM --output=avail "$target" 2>/dev/null | tail -n1 | tr -dc '0-9' || echo 0
}

build_image_docker() {
  local avail_mb
  avail_mb="$(free_disk_mb)"
  if [ "$avail_mb" -lt 12000 ]; then
    die "Not enough disk for a build (~12 GB free needed, $avail_mb MB free at $SRC_DIR)."
  fi
  clone_source

  # Resource caps tuned for 8 GB / 4-core WSL2 hosts. The OmniRoute Dockerfile
  # (v3.8.51) documents the OOM behaviour: Next.js workers each inherit
  # NODE_OPTIONS; CIRCLE_NODE_TOTAL caps worker count. Defaults below match the
  # Dockerfile's own conservative defaults (6144 MB heap is too much for an
  # 8 GB host once the Docker daemon is subtracted).
  local mem_limit swap_limit heap_mb workers
  if [ "$TOTAL_RAM_MB" -ge 16384 ]; then
    mem_limit="8g"; swap_limit="12g"; heap_mb=6144; workers=4
  else
    mem_limit="6g"; swap_limit="8g"; heap_mb=4096; workers=2
  fi
  local build_cmd=(DC)
  if run_quiet DC buildx version; then
    build_cmd+=(buildx build)
  else
    build_cmd+=(build)
    warn "docker buildx not available - using classic builder with DOCKER_BUILDKIT=1"
  fi

  log "Build resource caps: --memory=$mem_limit --memory-swap=$swap_limit"
  log "Build args: OMNIROUTE_BUILD_MEMORY_MB=$heap_mb OMNIROUTE_BUILD_WORKERS=$workers"
  log "           OMNIROUTE_USE_TURBOPACK=0 (webpack - the Docker default)"
  log "Builder: DOCKER_BUILDKIT=1 ${build_cmd[*]} (the Dockerfile requires BuildKit: --mount=type=cache)"

  run_quiet DC builder prune -af || true

  local rc=0
  set +e
  (
    cd "$SRC_DIR"
    DOCKER_BUILDKIT=1 "${build_cmd[@]}" \
      --pull \
      --memory "$mem_limit" \
      --memory-swap "$swap_limit" \
      --build-arg "OMNIROUTE_BUILD_MEMORY_MB=$heap_mb" \
      --build-arg "OMNIROUTE_BUILD_WORKERS=$workers" \
      --build-arg "OMNIROUTE_USE_TURBOPACK=0" \
      -t "${IMAGE_NAME}:latest" . 2>&1 | tee -a "$LOG_FILE"
  )
  rc=${PIPESTATUS[0]}
  set -e
  if [ "$rc" -ne 0 ]; then
    if grep -qiE "OOM|out of memory|Cannot allocate memory|Killed" "$LOG_FILE" 2>/dev/null; then
      warn "Build appears to have been OOM-killed."
    fi
    # NOT a hard stop: the caller (acquire_runtime) falls back to Node mode,
    # per the resource-constrained-host design. See $LOG_FILE for details.
    err "Docker build failed (exit $rc). See $LOG_FILE."
    return 1
  fi
  RUN_MODE="docker"
  log "Image built: ${IMAGE_NAME}:latest"
}

ensure_node_runtime() {
  local need=22
  if command -v node >/dev/null 2>&1; then
    local major
    major="$(node -p 'process.versions.node.split(".")[0]' 2>/dev/null || echo 0)"
    if [ "$major" -ge "$need" ]; then
      log "Node $(node --version) present (>= $need required)."
      return 0
    fi
    warn "Node $(node --version) is older than required ($need.x)."
  fi
  log "Installing Node.js 22 from NodeSource (nodesource.com)."
  if [ "$(id -u)" -ne 0 ] && [ -z "$SUDO" ]; then
    die "Need root or sudo to install Node.js $need."
  fi
  if curl -fsSL https://deb.nodesource.com/setup_22.x | $SUDO -E bash - >>"$LOG_FILE" 2>&1; then
    DEBIAN_FRONTEND=noninteractive run_logged $SUDO apt-get install -y --no-install-recommends nodejs
  else
    die "NodeSource setup failed (network blocked?). Install Node.js >= 22 manually and re-run."
  fi
}

npm_install_global() {
  # Two-registry fallback: npmjs.org is frequently unreachable from Iran;
  # registry.npmmirror.com (Alibaba mirror) usually is.
  local registry="${NPM_REGISTRY:-https://registry.npmjs.org}"
  log "npm install -g omniroute (registry: $registry)"
  if run_quiet npm install -g --no-audit --no-fund --registry "$registry" omniroute; then
    return 0
  fi
  if [ "$registry" != "https://registry.npmmirror.com" ]; then
    warn "npmjs.org failed - retrying via https://registry.npmmirror.com"
    if run_quiet npm install -g --no-audit --no-fund --registry "https://registry.npmmirror.com" omniroute; then
      return 0
    fi
  fi
  return 1
}

acquire_image_node() {
  log "=== Non-Docker mode: running OmniRoute directly with Node + pm2 ==="
  ensure_node_runtime
  if ! npm_install_global; then
    warn "npm package install failed - building from source instead."
    clone_source
    ( cd "$SRC_DIR" && run_logged npm ci --no-audit --no-fund )
    ( cd "$SRC_DIR" && run_logged npm run build )
  fi
  if ! command -v pm2 >/dev/null 2>&1; then
    log "Installing pm2 (auto-restart supervisor, the systemd replacement)."
    if ! npm_install_global_p2; then
      warn "pm2 install failed - falling back to a nohup process (no auto-restart)."
      PM2_AVAILABLE=0
    fi
  fi
  PM2_AVAILABLE=1
  RUN_MODE="node"
}

npm_install_global_p2() {
  local registry="${NPM_REGISTRY:-https://registry.npmjs.org}"
  run_quiet npm install -g --no-audit --no-fund --registry "$registry" pm2 ||
  run_quiet npm install -g --no-audit --no-fund --registry "https://registry.npmmirror.com" pm2
}

acquire_runtime() {
  if [ "${OMNIRoute_NO_DOCKER_BUILD:-0}" = "1" ] || ! command -v docker >/dev/null 2>&1; then
    if [ "${OMNIRoute_NO_DOCKER_BUILD:-0}" = "1" ]; then
      log "OMNIRoute_NO_DOCKER_BUILD=1 - using Node mode directly."
    else
      log "Docker unavailable - using Node mode."
    fi
    acquire_image_node
    return 0
  fi
  install_docker_if_missing
  ensure_docker_running
  configure_docker_mirrors
  ensure_docker_running
  if acquire_image_docker; then
    return 0
  fi
  if [ "${OMNIRoute_NO_DOCKER_BUILD:-0}" = "1" ]; then
    warn "Forcing Node mode (OMNIRoute_NO_DOCKER_BUILD=1)."
    acquire_image_node
    return 0
  fi
  if build_image_docker; then
    return 0
  fi
  warn "Docker build failed - final fallback: Node mode."
  acquire_image_node
}

# ---------------------------------------------------------------------------
# 8. Runtime configuration (.env) + master key
# ---------------------------------------------------------------------------
generate_master_key() {
  if [ -f "$MASTER_KEY_FILE" ] && grep -q "^sk-omni-" "$MASTER_KEY_FILE" 2>/dev/null; then
    MASTER_KEY="$(head -n1 "$MASTER_KEY_FILE" | tr -d '[:space:]')"
    log "Reusing existing master key from $MASTER_KEY_FILE"
  else
    MASTER_KEY="sk-omni-$(openssl rand -hex 16)"
    printf '%s\n' "$MASTER_KEY" >"$MASTER_KEY_FILE"
    chmod 600 "$MASTER_KEY_FILE"
    log "Generated new master key, stored in $MASTER_KEY_FILE (mode 600)."
  fi
}

write_env_file() {
  # The env file lives next to the data dir so it works for BOTH Docker
  # (--env-file) and Node mode (sourced by the launcher).
  local env_file="$DATA_DIR/.env"
  mkdir -p "$DATA_DIR"

  local jwt_secret api_key_secret initial_password
  if [ -f "$env_file" ]; then
    # Idempotent re-run: preserve secrets so dashboard login + API key
    # encryption keep working.
    jwt_secret="$(grep -E '^JWT_SECRET=' "$env_file" | cut -d= -f2- || true)"
    api_key_secret="$(grep -E '^API_KEY_SECRET=' "$env_file" | cut -d= -f2- || true)"
    initial_password="$(grep -E '^INITIAL_PASSWORD=' "$env_file" | cut -d= -f2- || true)"
    log "Reusing existing secrets from $env_file"
  fi
  [ -n "${jwt_secret:-}" ] || jwt_secret="$(openssl rand -base64 48 | tr -d '\n')"
  [ -n "${api_key_secret:-}" ] || api_key_secret="$(openssl rand -hex 32)"
  [ -n "${initial_password:-}" ] || initial_password="$(openssl rand -hex 12)"

  local tmp
  tmp="$(make_tmp)"
  {
    echo "# Managed by omniroute-manager.sh - regenerated on every install."
    echo "# Secrets (JWT/API_KEY/INITIAL_PASSWORD) are preserved across re-runs."
    echo "JWT_SECRET=$jwt_secret"
    echo "API_KEY_SECRET=$api_key_secret"
    echo "INITIAL_PASSWORD=$initial_password"
    echo "# Master key for /v1/* (OpenCode uses this)."
    echo "OMNIROUTE_API_KEY=$MASTER_KEY"
    echo "REQUIRE_API_KEY=true"
    echo "PORT=$OMNIRoute_PORT"
    echo "DASHBOARD_PORT=$OMNIRoute_PORT"
    echo "API_PORT=$OMNIRoute_API_PORT"
    echo "API_HOST=127.0.0.1"
    echo "DATA_DIR=/app/data"
    echo "OMNIROUTE_MITM_STUB=1"
    # Runtime heap: the image default (1024 MB) is fine; raise for fusion panels.
    echo "OMNIROUTE_MEMORY_MB=1024"
    # Headless escape hatch that IS honoured for Gemini (src/lib/providers/gemini.ts):
    # dashboard-created connections always win when both exist.
    if [ -n "${KEY_GEMINI:-}" ]; then
      echo "GEMINI_API_KEY=$KEY_GEMINI"
      echo "GOOGLE_API_KEY=$KEY_GEMINI"
    fi
    # NOTE: groq/openrouter/cerebras/mistral keys are NOT env vars in OmniRoute;
    # they are registered into the encrypted provider DB via the management API
    # (see register_provider_keys).
  } >"$tmp"
  mv "$tmp" "$env_file"
  chmod 600 "$env_file"
  ENV_FILE="$env_file"
  INITIAL_PASSWORD_SET="$initial_password"
  log "Wrote $env_file (mode 600)."
}

# ---------------------------------------------------------------------------
# 9. Start the service (Docker container or Node+pm2), idempotent
# ---------------------------------------------------------------------------
container_env_hash() {
  sha256sum "$ENV_FILE" 2>/dev/null | awk '{print $1}' || echo none
}

start_container() {
  local env_hash
  env_hash="$(container_env_hash)"

  if DC ps --format '{{.Names}}' 2>/dev/null | grep -qx "$CONTAINER_NAME"; then
    local existing_hash
    existing_hash="$(DC inspect --format '{{index .Config.Labels "omniroute.env-hash"}}' "$CONTAINER_NAME" 2>/dev/null || echo missing)"
    if [ "$existing_hash" = "$env_hash" ]; then
      log "Container $CONTAINER_NAME already running with current config - leaving it up."
      DC start "$CONTAINER_NAME" >>"$LOG_FILE" 2>&1 || true
      return 0
    fi
    log "Container $CONTAINER_NAME exists with an older config - recreating it."
    DC stop "$CONTAINER_NAME" >>"$LOG_FILE" 2>&1 || true
    DC rm "$CONTAINER_NAME" >>"$LOG_FILE" 2>&1 || true
  elif DC ps -a --format '{{.Names}}' 2>/dev/null | grep -qx "$CONTAINER_NAME"; then
    DC rm "$CONTAINER_NAME" >>"$LOG_FILE" 2>&1 || true
  fi

  log "Starting container $CONTAINER_NAME (restart policy: unless-stopped)."
  run_logged DC run -d \
    --name "$CONTAINER_NAME" \
    --restart unless-stopped \
    --label "omniroute.env-hash=$env_hash" \
    -p "${OMNIRoute_BIND_HOST}:${OMNIRoute_PORT}:${OMNIRoute_PORT}" \
    -p "${OMNIRoute_BIND_HOST}:${OMNIRoute_API_PORT}:${OMNIRoute_API_PORT}" \
    -v "${DATA_DIR}:/app/data" \
    --env-file "$ENV_FILE" \
    -e DATA_DIR=/app/data \
    "${IMAGE_NAME}:latest"
  # Mode marker: lets the quick commands (omni up/down/...) tell which
  # runtime manages OmniRoute on later invocations.
  echo "docker" >"$DATA_DIR/mode"
}

write_node_launcher() {
  # Deterministic launcher for Node mode: loads the managed .env and runs
  # `omniroute serve` with DATA_DIR pointing at the HOST data dir (the Docker
  # image uses /app/data instead). Used by both pm2 and the nohup fallback.
  local launcher="$HOME/omniroute-run.sh"
  local tmp
  tmp="$(make_tmp)"
  cat >"$tmp" <<LAUNCHER
#!/usr/bin/env bash
# Managed by omniroute-manager.sh (Node-mode launcher).
# Pick up the user's PATH (npm global bin etc.) - matters when started
# by a systemd unit at boot.
if [ -f "$HOME/.profile" ]; then . "$HOME/.profile" 2>/dev/null || true; fi
set -a
. "$ENV_FILE"
set +a
# Node mode runs on the host: DATA_DIR is the host directory, not /app/data.
export DATA_DIR="$DATA_DIR"
export PORT="$OMNIRoute_PORT"
exec omniroute serve
LAUNCHER
  mv "$tmp" "$launcher"
  chmod 700 "$launcher"
  NODE_LAUNCHER="$launcher"
  log "Wrote Node-mode launcher: $launcher"
}

start_node_process() {
  if [ -f "$NODE_MODE_PID_FILE" ]; then
    local pid
    pid="$(cat "$NODE_MODE_PID_FILE" 2>/dev/null || true)"
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
      log "Node OmniRoute already running (pid $pid) - leaving it up."
      return 0
    fi
    rm -f "$NODE_MODE_PID_FILE"
  fi
  write_node_launcher
  if [ "${PM2_AVAILABLE:-1}" = "1" ] && command -v pm2 >/dev/null 2>&1; then
    # pm2 acts as the systemd replacement: auto-restart on crash, and (after
    # 'pm2 startup') on boot. --interpreter bash runs the launcher wrapper.
    if ! run_logged pm2 start "$NODE_LAUNCHER" --name omniroute --interpreter bash --time; then
      die "pm2 failed to start omniroute."
    fi
    pm2 save >>"$LOG_FILE" 2>&1 || true
    pm2 startup systemd -u "$(whoami)" --hp "$HOME" >>"$LOG_FILE" 2>&1 \
      && log "pm2 autostart configured (if a sudo command was printed, run it once)." \
      || warn "pm2 startup not configured - OmniRoute will NOT auto-start after reboot."
  else
    log "Starting OmniRoute with nohup (no auto-restart available)."
    (
      nohup "$NODE_LAUNCHER" >>"$DATA_DIR/omniroute-node.log" 2>&1 &
      echo $! >"$NODE_MODE_PID_FILE"
    )
  fi
  # Mode marker (see start_container).
  echo "node" >"$DATA_DIR/mode"
}

# ---------------------------------------------------------------------------
# 10. Wait for health, then register provider keys via the management API
# ---------------------------------------------------------------------------
wait_for_health() {
  log "Waiting for $BASE_URL/healthz ..."
  local i attempt=0 max=60
  for i in $(seq 1 "$max"); do
    if curl -fsS --max-time 5 "$BASE_URL/healthz" >/dev/null 2>&1; then
      log "Health OK after $(( i * 5 ))s."
      return 0
    fi
    attempt=$i
    if [ $(( i % 6 )) -eq 0 ]; then
      log "Still waiting... ($(( i * 5 ))s). First boot can take 1-2 minutes."
      if [ "$RUN_MODE" = "docker" ]; then
        DC logs --tail 5 "$CONTAINER_NAME" 2>&1 | sed 's/^/    | /' | tee -a "$LOG_FILE" || true
      fi
    fi
  done
  if [ "$RUN_MODE" = "docker" ]; then
    warn "Last container log lines:"
    DC logs --tail 30 "$CONTAINER_NAME" 2>&1 | sed 's/^/    | /' | tee -a "$LOG_FILE" || true
  fi
  die "Service did not become healthy within $(( max * 5 ))s. Check $LOG_FILE."
}

dashboard_login() {
  log "Logging into the dashboard management API (loopback) to register provider keys."
  local jar
  jar="$(make_tmp)"
  local body rc=0
  set +e
  body="$(curl -fsS --max-time 15 -c "$jar" \
    -X POST "$BASE_URL/api/auth/login" \
    -H 'Content-Type: application/json' \
    -d "{\"password\":\"$INITIAL_PASSWORD_SET\"}")"
  rc=$?
  set -e
  if [ $rc -ne 0 ] || ! grep -q "auth_token" "$jar" 2>/dev/null; then
    warn "Login failed (rc=$rc, response: ${body:-<empty>})."
    warn "Provider keys could not be registered via the API. You can add them later in the"
    warn "dashboard: http://127.0.0.1:${OMNIRoute_PORT} (password: $INITIAL_PASSWORD_SET)"
    return 1
  fi
  log "Dashboard login OK (auth_token cookie obtained)."
  COOKIE_JAR="$jar"
  return 0
}

register_provider_keys() {
  # Headless registration: OmniRoute stores provider API keys in its encrypted
  # SQLite DB. The dashboard management API accepts an admin session cookie.
  # validateKeys=false: no upstream probe (provider networks may be blocked
  # in Iran; connections are validated lazily on first use).
  local -a pairs=()
  [ -n "${KEY_GROQ:-}" ]       && pairs+=("groq|$KEY_GROQ")
  [ -n "${KEY_OPENROUTER:-}" ] && pairs+=("openrouter|$KEY_OPENROUTER")
  [ -n "${KEY_GEMINI:-}" ]     && pairs+=("gemini|$KEY_GEMINI")
  [ -n "${KEY_CEREBRAS:-}" ]   && pairs+=("cerebras|$KEY_CEREBRAS")
  [ -n "${KEY_MISTRAL:-}" ]    && pairs+=("mistral|$KEY_MISTRAL")

  REGISTERED_OK=""; REGISTERED_FAIL=""
  if ! dashboard_login; then
    local q
    for q in "${pairs[@]}"; do REGISTERED_FAIL="$REGISTERED_FAIL ${q%%|*}"; done
    return 0
  fi

  local p k resp
  for pair in "${pairs[@]}"; do
    p="${pair%%|*}"; k="${pair#*|}"
    log "Registering provider connection: $p"
    set +e
    resp="$(curl -fsS --max-time 30 -b "$COOKIE_JAR" \
      -X POST "$BASE_URL/api/providers/bulk" \
      -H 'Content-Type: application/json' \
      -d "{\"provider\":\"$p\",\"entries\":[{\"name\":\"ws-install\",\"apiKey\":\"$k\"}],\"validateKeys\":false}")"
    local rc=$?
    set -e
    if [ $rc -eq 0 ] && printf '%s' "$resp" | jq -e '.created | length > 0' >/dev/null 2>&1; then
      REGISTERED_OK="$REGISTERED_OK $p"
      log "  -> $p registered."
    else
      REGISTERED_FAIL="$REGISTERED_FAIL $p"
      warn "  -> $p registration failed (rc=$rc). Response: ${resp:0:300}"
    fi
  done
}

# ---------------------------------------------------------------------------
# 11. OpenCode configuration (Windows path with spaces, JSONC-safe merge)
# ---------------------------------------------------------------------------
detect_opencode_dir() {
  # Order: explicit override -> PowerShell (handles UNC + spaces correctly;
  # cmd.exe is deliberately NOT used - it mangles UNC paths) -> /mnt/c scan
  # -> WSL home fallback.
  if [ -n "${OMNIRoute_OPENCODE_DIR:-}" ]; then
    log "OpenCode dir override: $OMNIRoute_OPENCODE_DIR"
    OPENCODE_DIR="$OMNIRoute_OPENCODE_DIR"
    return 0
  fi
  local raw=""
  if command -v powershell.exe >/dev/null 2>&1; then
    raw="$(powershell.exe -NoProfile -Command "[Environment]::GetFolderPath('UserProfile')" 2>/dev/null | tr -d '\r' | head -n1 || true)"
    log "PowerShell UserProfile: ${raw:-<empty>}"
  fi
  local win_dir=""
  if [ -n "$raw" ]; then
    if [[ "$raw" == /* ]]; then
      win_dir="$raw"
    elif command -v wslpath >/dev/null 2>&1; then
      win_dir="$(wslpath -u "$raw" 2>/dev/null | tr -d '\r' || true)"
    fi
    if [ -n "$win_dir" ]; then
      # Spaces in usernames are fine: everything is quoted end-to-end.
      OPENCODE_DIR="$win_dir/.config/opencode"
      log "OpenCode dir (Windows): $OPENCODE_DIR"
      return 0
    fi
  fi
  # Fallback: first real user dir under /mnt/c/Users (handles spaces via glob).
  local d
  for d in "$MNT_ROOT"/c/Users/*/; do
    d="${d%/}"
    [ -d "$d" ] || continue
    OPENCODE_DIR="$d/.config/opencode"
    log "OpenCode dir (fallback $MNT_ROOT/c scan): $OPENCODE_DIR"
    return 0
  done
  OPENCODE_DIR="$HOME/.config/opencode"
  warn "Windows user dir not detected - writing the WSL-side config: $OPENCODE_DIR"
}

fetch_catalog() {
  # Live model catalog from the running instance - the single source of truth
  # (same approach as OmniRoute's own opencode config generator).
  local out
  out="$(make_tmp)"
  if curl -fsS --max-time 30 -H "Authorization: Bearer $MASTER_KEY" \
      "$BASE_URL/v1/models" >"$out" 2>>"$LOG_FILE" \
    && jq -e '(.data? // .) | type == "array"' "$out" >/dev/null 2>&1; then
    CATALOG_FILE="$out"
    return 0
  fi
  warn "Could not fetch /v1/models catalog - opencode.json will use the built-in"
  warn "default model list without live context windows."
  CATALOG_FILE=""
  return 1
}

build_opencode_config() {
  local config_path="$OPENCODE_DIR/opencode.json"
  mkdir -p "$OPENCODE_DIR"

  # --- assemble provider block (jq-built, so secrets are escaped correctly) ---
  local models_json
  if [ -n "${CATALOG_FILE:-}" ]; then
    models_json="$(jq '[
        ((.data? // .))[]
        | select(type=="object" and (.id?|type=="string") and ((.id|length) > 0))
        | .id as $id
        | {
            name: (.display_name? // .name? // $id),
            limit: {
              context: ((.context_length? // .max_context_window_tokens? // 128000) | if type=="number" and . > 0 then . else 128000 end),
              output:  ((.max_output_tokens? // 8192) | if type=="number" and . > 0 then . else 8192 end)
            }
          }
        | {($id): .}
      ] | add // {}' "$CATALOG_FILE")"
  else
    # Static fallback (2026-09 free tier defaults).
    models_json="$(jq -n '{
      "devstral-latest":{"name":"Devstral 2","limit":{"context":262144,"output":8192}},
      "qwen/qwen3.8-27b":{"name":"Qwen3.8 27B","limit":{"context":262144,"output":8192}},
      "openai/gpt-oss-120b":{"name":"GPT-OSS 120B","limit":{"context":131072,"output":8192}},
      "gemini-2.5-flash":{"name":"Gemini 2.5 Flash","limit":{"context":1048576,"output":65536}},
      "codestral-latest":{"name":"Codestral","limit":{"context":262144,"output":8192}},
      "deepseek/deepseek-chat-v3-0324:free":{"name":"DeepSeek V3 0324 (free)","limit":{"context":163840,"output":8192}},
      "deepseek/deepseek-r1:free":{"name":"DeepSeek R1 (free)","limit":{"context":163840,"output":8192}},
      "zai-glm-4.7":{"name":"GLM 4.7","limit":{"context":200000,"output":8192}},
      "llama-3.3-70b":{"name":"Llama 3.3 70B","limit":{"context":131072,"output":8192}}
    }')"
  fi

  # The live /v1/models catalog can be several MB - far beyond the 128 KB
  # per-argument limit of `jq --argjson` (E2BIG: "Argument list too long").
  # Every payload therefore travels through temp files, never argv.
  local models_file provider_file base_file
  models_file="$(make_tmp)"; provider_file="$(make_tmp)"; base_file="$(make_tmp)"
  printf '%s' "$models_json" >"$models_file"
  jq --arg baseURL "${BASE_URL}/v1" \
     --arg apiKey "$MASTER_KEY" \
     '{
       name: "OmniRoute",
       npm: "@ai-sdk/openai-compatible",
       options: { baseURL: $baseURL, apiKey: $apiKey },
       models: .
     }' "$models_file" >"$provider_file"

  # --- choose the default model from the live catalog ---
  local default_model="" m
  for m in "${PREFERRED_MODELS[@]}"; do
    if [ -n "${CATALOG_FILE:-}" ] && jq -e --arg m "$m" '((.data? // .) | map(.id) | index($m)) != null' "$CATALOG_FILE" >/dev/null 2>&1; then
      default_model="$m"; break
    fi
  done
  if [ -z "$default_model" ] && [ -n "${CATALOG_FILE:-}" ]; then
    default_model="$(jq -r '((.data? // .) | map(.id) | .[0]) // empty' "$CATALOG_FILE")"
  fi
  [ -n "$default_model" ] || default_model="${PREFERRED_MODELS[0]}"
  log "Default OpenCode model: omniroute/$default_model"

  # --- merge with any existing config (preserve other providers/keys) ---
  # The existing config also goes through a file (it can be large too).
  if [ -f "$config_path" ]; then
    if jq -e . "$config_path" >/dev/null 2>&1; then
      jq . "$config_path" >"$base_file"
    else
      local bak="${config_path}.bak-$(date +%Y%m%d%H%M%S)"
      warn "Existing $config_path is not valid JSON - backing up to $bak and writing a clean file."
      cp "$config_path" "$bak" 2>/dev/null || true
      printf '{}\n' >"$base_file"
    fi
  else
    printf '{}\n' >"$base_file"
  fi

  # -s slurps both files: .[0] = base, .[1] = provider.
  local tmp
  tmp="$(make_tmp)"
  jq -s --arg defaultModel "omniroute/$default_model" '
      .[0] as $base | .[1] as $provider
      | $base as $b
      | ($b | if has("$schema") then . else . + {"$schema": "https://opencode.ai/config.json"} end)
      | .provider = (($b.provider // {}) + {"omniroute": $provider})
      # Keep an existing top-level model unless it is empty or already points
      # at OmniRoute (in which case it is refreshed to the current default).
      | .model = (
          if ($b.model // "") == "" then $defaultModel
          elif ($b.model | startswith("omniroute/")) then $defaultModel
          else $b.model
          end)
    ' "$base_file" "$provider_file" >"$tmp"
  jq -e . "$tmp" >/dev/null || die "Internal error: generated opencode.json is invalid."
  mv "$tmp" "$config_path"
  chmod 644 "$config_path"
  log "Wrote OpenCode config: $config_path"
  OPENCODE_CONFIG_PATH="$config_path"
  MODEL_COUNT="$(jq '.provider.omniroute.models | length' "$config_path")"
}

# ---------------------------------------------------------------------------
# 12. Post-install verification (6 automated tests)
# ---------------------------------------------------------------------------
TEST_RESULTS=()
TEST_PASSED=0

report_test() {
  local n="$1" name="$2" ok="$3" detail="${4:-}"
  if [ "$ok" = "0" ]; then
    TEST_RESULTS+=("PASS  $n) $name")
    TEST_PASSED=$((TEST_PASSED + 1))
  else
    TEST_RESULTS+=("FAIL  $n) $name${detail:+ - $detail}")
  fi
  _log "$([ "$ok" = "0" ] && echo PASS || echo FAIL)" "$name${detail:+ - $detail}"
}

run_verification() {
  log "=== Post-install verification ==="

  # 1) Docker daemon running (or Node runtime in Node mode)
  if [ "$RUN_MODE" = "docker" ]; then
    if run_quiet DC info >/dev/null 2>&1; then
      report_test 1 "Docker daemon is running" 0
    else
      report_test 1 "Docker daemon is running" 1 "docker info failed"
    fi
  else
    if command -v node >/dev/null 2>&1 && command -v omniroute >/dev/null 2>&1; then
      report_test 1 "Node runtime + omniroute CLI available" 0
    else
      report_test 1 "Node runtime + omniroute CLI available" 1 "node or omniroute missing"
    fi
  fi

  # 2) Container/process up
  if [ "$RUN_MODE" = "docker" ]; then
    if DC ps --format '{{.Names}}' 2>/dev/null | grep -qx "$CONTAINER_NAME"; then
      report_test 2 "Container $CONTAINER_NAME is up" 0
    else
      report_test 2 "Container $CONTAINER_NAME is up" 1 "not in docker ps"
    fi
  else
    local pid=""
    [ -f "$NODE_MODE_PID_FILE" ] && pid="$(cat "$NODE_MODE_PID_FILE" 2>/dev/null || true)"
    if [ "${PM2_AVAILABLE:-1}" = "1" ] && command -v pm2 >/dev/null 2>&1; then
      pm2 jlist 2>/dev/null | jq -e '.[] | select(.name=="omniroute" and .pm2_env.status=="online")' >/dev/null 2>&1 \
        && report_test 2 "pm2 process omniroute is online" 0 \
        || report_test 2 "pm2 process omniroute is online" 1 "pm2 status"
    elif [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
      report_test 2 "Node process (pid $pid) is running" 0
    else
      report_test 2 "Node process is running" 1 "pid not alive"
    fi
  fi

  # 3) Health endpoint (10 attempts x 3s as specified; service already waited
  #    on during startup, so this is a fast re-check)
  local ok=1 i
  for i in $(seq 1 10); do
    if curl -fsS --max-time 5 "$BASE_URL/healthz" >/dev/null 2>&1; then ok=0; break; fi
    sleep 3
  done
  report_test 3 "Health endpoint $BASE_URL/healthz responds" "$ok" "no 2xx after 10 attempts"

  # 4) Models endpoint returns JSON (authenticated with the master key)
  local models_body="" rc=0
  set +e
  models_body="$(curl -fsS --max-time 30 -H "Authorization: Bearer $MASTER_KEY" "$BASE_URL/v1/models")"
  rc=$?
  set -e
  if [ $rc -eq 0 ] && printf '%s' "$models_body" | jq -e '(.data? // .) | type == "array"' >/dev/null 2>&1; then
    local n
    n="$(printf '%s' "$models_body" | jq '(.data? // .) | length')"
    report_test 4 "/v1/models returns JSON" 0 "$n models"
  else
    report_test 4 "/v1/models returns JSON" 1 "rc=$rc (wrong key or service issue)"
  fi

  # 5) Real chat completion with the default model (non-streaming, tiny)
  local test_model rc2=0 body2=""
  test_model="$(jq -r '.model // empty' "$OPENCODE_CONFIG_PATH" 2>/dev/null | sed 's#^omniroute/##')"
  [ -n "$test_model" ] || test_model="${PREFERRED_MODELS[0]}"
  set +e
  body2="$(curl -fsS --max-time 90 \
    -H "Authorization: Bearer $MASTER_KEY" -H 'Content-Type: application/json' \
    -X POST "$BASE_URL/v1/chat/completions" \
    -d "{\"model\":\"$test_model\",\"messages\":[{\"role\":\"user\",\"content\":\"Hello\"}],\"max_tokens\":32}")"
  rc2=$?
  set -e
  if [ $rc2 -eq 0 ] && printf '%s' "$body2" | jq -e '.choices[0].message.content' >/dev/null 2>&1; then
    local snippet
    snippet="$(printf '%s' "$body2" | jq -r '.choices[0].message.content' | head -c 80 | tr '\n' ' ')"
    report_test 5 "Chat completion via $test_model" 0 "\"$snippet\""
  else
    report_test 5 "Chat completion via $test_model" 1 \
      "rc=$rc2 ${body2:0:200}"
  fi

  # 6) OpenCode config exists and is valid JSON
  if [ -f "$OPENCODE_CONFIG_PATH" ] && jq -e . "$OPENCODE_CONFIG_PATH" >/dev/null 2>&1; then
    report_test 6 "OpenCode config valid JSON: $OPENCODE_CONFIG_PATH" 0
  else
    report_test 6 "OpenCode config valid JSON: $OPENCODE_CONFIG_PATH" 1 "missing or invalid"
  fi

  log "Verification: $TEST_PASSED/6 tests passed."
}

# ---------------------------------------------------------------------------
# 13. Final banner
# ---------------------------------------------------------------------------
provider_key_set() {
  case "$1" in
    groq) [ -n "${KEY_GROQ:-}" ] ;;
    openrouter) [ -n "${KEY_OPENROUTER:-}" ] ;;
    gemini) [ -n "${KEY_GEMINI:-}" ] ;;
    cerebras) [ -n "${KEY_CEREBRAS:-}" ] ;;
    mistral) [ -n "${KEY_MISTRAL:-}" ] ;;
  esac
}

provider_status_line() {
  local out="" p state
  for p in groq openrouter gemini cerebras mistral; do
    state="-"
    if [ -n "${REGISTERED_OK:-}" ] && [[ " $REGISTERED_OK " == *" $p "* ]]; then
      state="OK"
    elif [ -n "${REGISTERED_FAIL:-}" ] && [[ " $REGISTERED_FAIL " == *" $p "* ]]; then
      state="FAILED"
    elif provider_key_set "$p"; then
      state="PENDING"
    fi
    out+="$p=$state | "
  done
  echo "${out% | }"
}

print_success_banner() {
  local status_line
  status_line="$(provider_status_line)"
  local svc_cmds="docker logs -f $CONTAINER_NAME"
  local svc_cmd2="docker restart $CONTAINER_NAME"
  [ "$RUN_MODE" = "node" ] && { svc_cmds="pm2 logs omniroute"; svc_cmd2="pm2 restart omniroute"; }

  cat <<EOF
============================================================
  [OK] Installation Successful
============================================================
  Service URL:  ${BASE_URL}/v1
  Dashboard:    ${BASE_URL}   (password: ${INITIAL_PASSWORD_SET})
  API Key:      ${MASTER_KEY}
  Config Path:  ${OPENCODE_CONFIG_PATH}
  Log File:     ${LOG_FILE}

  Available Models: ${MODEL_COUNT:-0}
  Provider Status:  ${status_line}

  Next Steps:
  1. Open OpenCode on Windows
  2. Select provider: 'omniroute'
  3. Choose a model and start coding

  Quick Commands (installed as 'omni'):
    omni status    # state + health
    omni up        # start the service
    omni down      # stop the service
    omni restart   # restart the service
    omni logs      # last 50 log lines (omni logs f = follow)
    omni uninstall # full removal

  Useful Commands:
    ${svc_cmds}     # View logs
    ${svc_cmd2}     # Restart service
    bash "${SCRIPT_PATH}"  # Re-run manager (this file)

  Notes:
  - If OpenCode on Windows cannot reach ${BASE_URL}, open a WSL2
    terminal and run: ip addr (check the WSL IP), or set
    OMNIRoute_BIND_HOST=0.0.0.0 and re-run the installer.
  - Provider keys that showed FAILED can be added any time in the
    dashboard under Settings -> Providers.
============================================================
EOF
}

# ---------------------------------------------------------------------------
# 13b. Quick management (omni up / down / restart / status / logs)
# ---------------------------------------------------------------------------
manage_service() {
  local op="$1" logs_arg="${2:-}"
  log "########## OmniRoute manage: $op (manager v${SCRIPT_VERSION}) ##########"
  detect_environment
  resolve_sudo

  # Detect the managed runtime: mode marker first, then live detection.
  local mode_file="$DATA_DIR/mode" mode=""
  if [ -f "$mode_file" ]; then
    mode="$(tr -d '[:space:]' <"$mode_file" 2>/dev/null || true)"
  fi
  if [ -z "$mode" ] && command -v docker >/dev/null 2>&1; then
    if DC ps -a --format '{{.Names}}' 2>/dev/null | grep -qx "$CONTAINER_NAME"; then
      mode="docker"
    fi
  fi
  if [ -z "$mode" ] && [ -f "$HOME/omniroute-run.sh" ]; then
    mode="node"
  fi
  [ -n "$mode" ] || die "No OmniRoute installation found (marker $mode_file missing). Run the install first."
  log "Detected mode: $mode"

  local container_up=0
  if [ "$mode" = "docker" ]; then
    if DC ps --format '{{.Names}}' 2>/dev/null | grep -qx "$CONTAINER_NAME"; then
      container_up=1
    fi
  fi

  case "$mode:$op" in
    docker:up)
      if [ "$container_up" = "1" ]; then
        log "Container $CONTAINER_NAME is already up."
      else
        DC start "$CONTAINER_NAME" >>"$LOG_FILE" 2>&1 || die "docker start failed (see $LOG_FILE)."
        log "Container $CONTAINER_NAME started."
      fi
      ;;
    docker:down)
      DC stop "$CONTAINER_NAME" >>"$LOG_FILE" 2>&1 || warn "Container was not running."
      log "Container stopped (image kept; 'omni up' starts it again)."
      ;;
    docker:restart)
      DC restart "$CONTAINER_NAME" >>"$LOG_FILE" 2>&1 || die "docker restart failed (see $LOG_FILE)."
      log "Container restarted."
      ;;
    docker:status)
      echo "OmniRoute mode:   docker (container $CONTAINER_NAME: $([ "$container_up" = "1" ] && echo running || echo stopped))"
      echo "Service URL:      $BASE_URL/v1"
      if curl -fsS --max-time 5 "$BASE_URL/healthz" >/dev/null 2>&1; then
        echo "Health:           OK"
      else
        echo "Health:           NOT reachable at $BASE_URL/healthz"
      fi
      ;;
    docker:logs)
      if [ "$logs_arg" = "f" ] || [ "$logs_arg" = "--follow" ]; then
        exec DC logs -f "$CONTAINER_NAME"
      fi
      DC logs --tail "${logs_arg:-50}" "$CONTAINER_NAME" 2>&1 | tail -n "${logs_arg:-50}"
      ;;
    node:up)
      if command -v pm2 >/dev/null 2>&1; then
        if pm2 jlist 2>/dev/null | jq -e '.[] | select(.name=="omniroute" and .pm2_env.status=="online")' >/dev/null 2>&1; then
          log "omniroute is already online in pm2."
        else
          pm2 start omniroute >>"$LOG_FILE" 2>&1 \
            || pm2 start "$HOME/omniroute-run.sh" --name omniroute --interpreter bash --time >>"$LOG_FILE" 2>&1 \
            || die "pm2 start failed (see $LOG_FILE)."
          log "omniroute started via pm2."
        fi
      else
        nohup "$HOME/omniroute-run.sh" >>"$DATA_DIR/omniroute-node.log" 2>&1 &
        echo $! >"$NODE_MODE_PID_FILE"
        log "omniroute started via nohup (pid $(cat "$NODE_MODE_PID_FILE"))."
      fi
      ;;
    node:down)
      if command -v pm2 >/dev/null 2>&1; then
        pm2 stop omniroute >>"$LOG_FILE" 2>&1 || true
      fi
      if [ -f "$NODE_MODE_PID_FILE" ]; then
        kill "$(cat "$NODE_MODE_PID_FILE" 2>/dev/null)" 2>/dev/null || true
      fi
      log "omniroute stopped."
      ;;
    node:restart)
      if command -v pm2 >/dev/null 2>&1; then
        pm2 restart omniroute >>"$LOG_FILE" 2>&1 || die "pm2 restart failed (see $LOG_FILE)."
        log "omniroute restarted via pm2."
      else
        manage_service "down"
        manage_service "up"
      fi
      ;;
    node:status)
      local st="stopped"
      if command -v pm2 >/dev/null 2>&1 && \
         pm2 jlist 2>/dev/null | jq -e '.[] | select(.name=="omniroute" and .pm2_env.status=="online")' >/dev/null 2>&1; then
        st="online (pm2)"
      fi
      echo "OmniRoute mode:   node ($st)"
      echo "Service URL:      $BASE_URL/v1"
      if curl -fsS --max-time 5 "$BASE_URL/healthz" >/dev/null 2>&1; then
        echo "Health:           OK"
      else
        echo "Health:           NOT reachable at $BASE_URL/healthz"
      fi
      ;;
    node:logs)
      if command -v pm2 >/dev/null 2>&1; then
        if [ "$logs_arg" = "f" ] || [ "$logs_arg" = "--follow" ]; then
          exec pm2 logs omniroute
        fi
        pm2 logs omniroute --nostream --lines "${logs_arg:-50}" 2>/dev/null \
          || tail -n "${logs_arg:-50}" "$DATA_DIR/omniroute-node.log"
      else
        tail -n "${logs_arg:-50}" "$DATA_DIR/omniroute-node.log"
      fi
      ;;
    *)
      die "Unknown manage operation: $op"
      ;;
  esac
  log "########## OmniRoute manage: $op finished ##########"
}

# ---------------------------------------------------------------------------
# 13c. Boot autostart (systemd)
# ---------------------------------------------------------------------------
configure_autostart() {
  if ! systemd_active; then
    warn "systemd is not active - skipping boot autostart."
    warn "The service will not start when WSL reboots. Enable systemd in"
    warn "/etc/wsl.conf ([boot] systemd=true) and re-run the install."
    return 0
  fi
  if [ "$RUN_MODE" = "docker" ]; then
    # Containers run with --restart unless-stopped; enabling the docker
    # service brings the daemon (and thus the container) up on WSL boot.
    if $SUDO systemctl enable docker >>"$LOG_FILE" 2>&1; then
      log "Docker service enabled at boot (container auto-starts with it)."
    else
      warn "Could not enable docker.service - start Docker manually after WSL reboot."
    fi
  else
    local unit_dir="$HOME/.config/systemd/user"
    local unit_file="$unit_dir/omniroute.service"
    mkdir -p "$unit_dir"
    cat >"$unit_file" <<UNIT
[Unit]
Description=OmniRoute (Node mode)
After=network-online.target
Wants=network-online.target

[Service]
ExecStart=%h/omniroute-run.sh
Restart=always
RestartSec=5

[Install]
WantedBy=default.target
UNIT
    if systemctl --user daemon-reload >>"$LOG_FILE" 2>&1 \
       && systemctl --user enable omniroute.service >>"$LOG_FILE" 2>&1; then
      log "systemd user unit 'omniroute' enabled (Node-mode boot autostart)."
      if ! loginctl show-user "$USER" 2>/dev/null | grep -q "Linger=yes"; then
        if $SUDO loginctl enable-linger "$USER" >>"$LOG_FILE" 2>&1; then
          log "Login linger enabled - the unit starts at boot without a login."
        else
          warn "Run once for boot autostart: sudo loginctl enable-linger $USER"
        fi
      fi
    else
      warn "Could not enable the systemd user unit. Start manually: bash $HOME/omniroute-run.sh"
    fi
  fi
}

remove_autostart() {
  local unit_file="$HOME/.config/systemd/user/omniroute.service"
  if [ -f "$unit_file" ]; then
    systemctl --user disable omniroute.service >/dev/null 2>&1 || true
    systemctl --user daemon-reload >/dev/null 2>&1 || true
    rm -f "$unit_file"
    log "Removed systemd user unit: omniroute.service"
  fi
  # docker.service stays enabled (it is a system service, not ours).
}

# ---------------------------------------------------------------------------
# 13d. Quick management command (omni)
# ---------------------------------------------------------------------------
OMNI_CMD_PATH=""
install_omni_shim() {
  local target="/usr/local/bin/omni"
  local tmp
  tmp="$(make_tmp)"
  cat >"$tmp" <<SHIM
#!/usr/bin/env bash
# OmniRoute quick management (generated by OmniRoute.sh v${SCRIPT_VERSION}).
MANAGER="${SCRIPT_PATH}"
cmd="\${1:-status}"
[ "\$#" -gt 0 ] && shift
case "\$cmd" in
  up|start)       exec bash "\$MANAGER" --up "\$@" ;;
  down|stop)      exec bash "\$MANAGER" --down "\$@" ;;
  restart)        exec bash "\$MANAGER" --restart "\$@" ;;
  status)         exec bash "\$MANAGER" --status "\$@" ;;
  logs)           exec bash "\$MANAGER" --logs "\$@" ;;
  install)        exec bash "\$MANAGER" --install "\$@" ;;
  uninstall)      exec bash "\$MANAGER" --uninstall "\$@" ;;
  help|--help|-h) echo "Usage: omni {up|down|restart|status|logs [N|f]|install|uninstall}" ;;
  *) echo "Unknown command: \$cmd (try: omni help)" >&2; exit 2 ;;
esac
SHIM
  chmod 755 "$tmp"
  if [ "$(id -u)" -eq 0 ]; then
    mv "$tmp" "$target"
  elif $SUDO mv "$tmp" "$target" 2>/dev/null && $SUDO chmod 755 "$target" 2>/dev/null; then
    :
  else
    target="$HOME/.local/bin/omni"
    mkdir -p "$(dirname "$target")"
    mv "$tmp" "$target"
    warn "$target installed. Make sure ~/.local/bin is in your PATH, e.g.:"
    warn '  export PATH="$HOME/.local/bin:$PATH"'
  fi
  OMNI_CMD_PATH="$target"
  log "Quick management command installed: $target  (omni up | down | restart | status | logs | uninstall)"
}

remove_omni_shim() {
  local p
  for p in /usr/local/bin/omni "$HOME/.local/bin/omni"; do
    if [ -e "$p" ] || [ -L "$p" ]; then
      if $SUDO rm -f "$p" 2>/dev/null || rm -f "$p" 2>/dev/null; then
        log "Removed quick command: $p"
      fi
    fi
  done
}

# ---------------------------------------------------------------------------
# 14. Install orchestrator
# ---------------------------------------------------------------------------
do_install() {
  log "########## OmniRoute install started (manager v${SCRIPT_VERSION}) ##########"
  detect_environment
  require_tools
  ensure_swap
  collect_keys
  acquire_runtime
  generate_master_key
  write_env_file
  if [ "$RUN_MODE" = "docker" ]; then
    start_container
  else
    start_node_process
  fi
  wait_for_health
  register_provider_keys
  detect_opencode_dir
  # Advisory step: on failure the built-in model list is used. The function
  # returns 1 when the live catalog is unavailable, so keep set -e from
  # treating that (expected) outcome as fatal.
  fetch_catalog || true
  build_opencode_config
  run_verification
  configure_autostart
  install_omni_shim
  print_success_banner
  log "########## OmniRoute install finished ##########"
}

# ---------------------------------------------------------------------------
# 15. Uninstall
# ---------------------------------------------------------------------------
confirm_uninstall() {
  if [ "$ASSUME_YES" -eq 1 ]; then
    log "Uninstall confirmed via --yes."
    return 0
  fi
  if is_tty; then
    prompt_yes_no "This removes the OmniRoute container, image, source, data and the" \
      "OpenCode 'omniroute' provider config. Continue?" "n" || die "Aborted by user."
    return 0
  fi
  die "Non-interactive uninstall requires --yes (and optionally --remove-docker). Aborted."
}

do_uninstall() {
  log "########## OmniRoute uninstall started ##########"
  _log_init
  confirm_uninstall
  resolve_sudo

  # 1) Stop + remove container (Docker mode).
  if command -v docker >/dev/null 2>&1; then
    if DC ps -a --format '{{.Names}}' 2>/dev/null | grep -qx "$CONTAINER_NAME"; then
      log "Stopping container $CONTAINER_NAME."
      DC stop "$CONTAINER_NAME" >>"$LOG_FILE" 2>&1 || true
      DC rm "$CONTAINER_NAME" >>"$LOG_FILE" 2>&1 || true
      log "Container removed."
    else
      log "Container $CONTAINER_NAME not present."
    fi
    # 2) Remove image(s) created/kept by this manager (local tag + any
    #    pre-built references still in the store).
    local img
    local img_refs=("${IMAGE_NAME}:latest" "${PREBUILT_REF:-}" \
      "${IMAGE_GHCR}:${IMAGE_TAG}" "${IMAGE_HUB}:${IMAGE_TAG}" \
      "${IMAGE_GHCR}:${IMAGE_TAG_PIN}" "${IMAGE_HUB}:${IMAGE_TAG_PIN}")
    for img in "${img_refs[@]}"; do
      [ -n "$img" ] || continue
      if DC images -q "$img" 2>/dev/null | grep -q .; then
        log "Removing image $img."
        DC rmi "$img" >>"$LOG_FILE" 2>&1 || warn "Could not remove image $img (in use?)"
      fi
    done
  else
    log "Docker CLI not present - nothing to remove."
  fi

  # 3) Node mode: kill pm2 process / pidfile process.
  if command -v pm2 >/dev/null 2>&1; then
    if pm2 jlist 2>/dev/null | jq -e '.[] | select(.name=="omniroute")' >/dev/null 2>&1; then
      log "Deleting pm2 process 'omniroute'."
      pm2 delete omniroute >>"$LOG_FILE" 2>&1 || true
      pm2 save >>"$LOG_FILE" 2>&1 || true
    fi
  fi
  if [ -f "$NODE_MODE_PID_FILE" ]; then
    local pid
    pid="$(cat "$NODE_MODE_PID_FILE" 2>/dev/null || true)"
    [ -n "$pid" ] && kill "$pid" 2>/dev/null || true
    rm -f "$NODE_MODE_PID_FILE"
    log "Node-mode process stopped."
  fi
  if [ -f "$HOME/omniroute-run.sh" ]; then
    rm -f "$HOME/omniroute-run.sh"
    log "Removed Node-mode launcher: $HOME/omniroute-run.sh"
  fi
  # 3b) Autostart + quick command.
  remove_autostart
  remove_omni_shim

  # 4) Source + data + secrets.
  log "Removing source: $SRC_DIR"
  rm -rf "$SRC_DIR" 2>/dev/null || true
  log "Removing data: $DATA_DIR"
  rm -rf "$DATA_DIR" 2>/dev/null || true
  log "Removing key stores: $KEYS_FILE, $MASTER_KEY_FILE"
  rm -f "$KEYS_FILE" "$MASTER_KEY_FILE" 2>/dev/null || true

  # 5) OpenCode config (with confirmation in interactive mode).
  local opencode_dir=""
  if [ -n "${OMNIRoute_OPENCODE_DIR:-}" ]; then
    opencode_dir="$OMNIRoute_OPENCODE_DIR"
  elif command -v powershell.exe >/dev/null 2>&1; then
    local raw
    raw="$(powershell.exe -NoProfile -Command "[Environment]::GetFolderPath('UserProfile')" 2>/dev/null | tr -d '\r' | head -n1 || true)"
    if [ -n "$raw" ] && command -v wslpath >/dev/null 2>&1; then
      opencode_dir="$(wslpath -u "$raw" 2>/dev/null | tr -d '\r')/.config/opencode"
    fi
  fi
  [ -n "$opencode_dir" ] || opencode_dir="$HOME/.config/opencode"
  local cfg="$opencode_dir/opencode.json"
  if [ -f "$cfg" ]; then
    if [ "$ASSUME_YES" -eq 1 ] || is_tty; then
      if [ "$ASSUME_YES" -eq 1 ] || prompt_yes_no "Delete $cfg ?" "y"; then
        rm -f "$cfg" && log "Deleted OpenCode config: $cfg" || warn "Could not delete $cfg"
      fi
    else
      warn "Non-interactive mode: leaving $cfg in place. Delete it manually if desired."
    fi
  else
    log "No OpenCode config found at $cfg."
  fi

  # 6) Optional: remove Docker itself.
  if [ "$REMOVE_DOCKER" -eq 1 ]; then
    if command -v docker >/dev/null 2>&1; then
      warn "Removing Docker (docker.io) as requested via --remove-docker."
      $SUDO systemctl stop docker 2>/dev/null || service docker stop 2>/dev/null || true
      DEBIAN_FRONTEND=noninteractive run_logged $SUDO apt-get remove -y docker.io 2>/dev/null ||
      DEBIAN_FRONTEND=noninteractive run_logged $SUDO apt-get remove -y docker.io containerd runc
      $SUDO rm -rf /var/lib/docker /etc/docker 2>/dev/null || true
      log "Docker removed."
    fi
  fi

  log "Uninstall complete. Log: $LOG_FILE"
  log "########## OmniRoute uninstall finished ##########"
}

# ---------------------------------------------------------------------------
# 16. Menu + entry point
# ---------------------------------------------------------------------------
usage() {
  cat <<'EOF'
OmniRoute + OpenCode manager (v1.0.0)

Usage:
  bash OmniRoute.sh               interactive menu (TTY required)
  bash OmniRoute.sh --install     run the full install
  bash OmniRoute.sh --uninstall   run the full uninstall
      --yes                               assume confirmation for uninstall
      --remove-docker                     also remove Docker itself (uninstall)
  bash OmniRoute.sh --up|--down|--restart|--status|--logs [N|f]
                                      quick management (also: omni up|...)
      --help                              this text

Environment overrides: OMNIRoute_PORT, OMNIRoute_API_PORT, OMNIRoute_BIND_HOST,
  OMNIRoute_SRC_DIR, OMNIRoute_DATA_DIR, OMNIRoute_LOG, OMNIRoute_CONTAINER,
  OMNIRoute_IMAGE_TAG, OMNIRoute_IMAGE_TAG_PIN, OMNIRoute_NPM_REGISTRY,
  OMNIRoute_OPENCODE_DIR, OMNIRoute_GROQ_KEY, OMNIRoute_OPENROUTER_KEY,
  OMNIRoute_GEMINI_KEY, OMNIRoute_CEREBRAS_KEY, OMNIRoute_MISTRAL_KEY,
  OMNIRoute_ASSUME_DEPS, OMNIRoute_SKIP_SWAP, OMNIRoute_NO_DOCKER_BUILD.
EOF
}

parse_args() {
  while [ $# -gt 0 ]; do
    case "$1" in
      --install) MODE="install" ;;
      --uninstall) MODE="uninstall" ;;
      --up|--start) MODE="up" ;;
      --down|--stop) MODE="down" ;;
      --restart) MODE="restart" ;;
      --status) MODE="status" ;;
      --logs)
        MODE="logs"
        if [ -n "${2:-}" ] && [ "${2:0:1}" != "-" ]; then
          LOGS_OPT="$2"
          shift
        fi
        ;;
      --yes|-y) ASSUME_YES=1 ;;
      --remove-docker) REMOVE_DOCKER=1 ;;
      --help|-h) usage; exit 0 ;;
      *) die "Unknown argument: $1 (see --help)" ;;
    esac
    shift
  done
}

main_menu() {
  cat <<EOF
============================================================
  OmniRoute + OpenCode Manager (v${SCRIPT_VERSION})
============================================================
  1) Full Install
  2) Full Uninstall
============================================================
EOF
  local choice
  prompt_line "Choose an option" "" ""
  choice="$REPLY_LINE"
  case "$choice" in
    1) MODE="install" ;;
    2) MODE="uninstall" ;;
    *) die "No option selected - exiting." ;;
  esac
}

main() {
  _log_init
  SCRIPT_PATH="${BASH_SOURCE[0]:-$0}"
  parse_args "$@"
  if [ -z "$MODE" ]; then
    if is_tty; then
      main_menu
    else
      err "No action selected. Non-TTY sessions must pass --install or --uninstall."
      usage
      exit 2
    fi
  fi
  case "$MODE" in
    install) do_install ;;
    uninstall) do_uninstall ;;
    up|down|restart|status|logs) manage_service "$MODE" "${LOGS_OPT:-}" ;;
  esac
}

main "$@"
