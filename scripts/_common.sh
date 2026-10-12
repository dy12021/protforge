#!/usr/bin/env bash
# ProtForge — shared helpers for all tool runner scripts.
# Source this file: source "$(dirname "$0")/../../../scripts/_common.sh"
#
# Backwards compatibility: deployments created before the OIH -> ProtForge
# rename keep working. Every helper prefers the new name and falls back to the
# legacy one, so renaming the plugin never invalidates existing containers,
# model weights or job outputs.

# Prevent Git Bash (MSYS) from rewriting container paths/args as Windows paths.
export MSYS2_ARG_CONV_EXCL='*'

# ---------------------------------------------------------------------------
# Paths
# ---------------------------------------------------------------------------

# Data root. Legacy $OIH_HOME still wins if it is set, so an existing shell
# profile or scheduled task keeps pointing at the same weights and outputs.
# With neither variable set, prefer E:/protforge, but fall back to E:/oih when
# that is where the deployment actually lives.
# Discovery uses the same printf + command-substitution shape as
# protforge_host_python / protforge_compose_file below. A conditional
# assignment inside if/elif branches did not reliably survive parameter
# expansion on every MSYS/Git Bash build: PROTORGE_HOME ended up empty, so
# PROTORGE_DATA collapsed to "/data" and every runner died on
# `mkdir: cannot create directory '/data'` before touching Docker.
protforge_detect_home() {
  local c
  for c in "E:/protforge" "E:/oih"; do
    if [ -d "$c" ]; then printf '%s\n' "$c"; return 0; fi
  done
  printf '%s\n' "E:/protforge"
}

# IMPORTANT: these three assignments must stay at top level, never inside an
# `if` body. On the Git Bash build shipped with this machine, assigning to
# PROTORGE_HOME from within a conditional block silently fails to persist
# (verified with an 8-case bisect: unconditional assignment and eval-wrapped
# assignment both work, if-body / printf -v / declare -g / read all do not).
# The symptom was PROTORGE_HOME empty -> PROTORGE_DATA "/data" -> every
# runner died on `mkdir: cannot create directory '/data'`.
# Unconditional `${VAR:-...}` keeps the OIH_* legacy fallback intact.
PROTFORGE_HOME="${PROTFORGE_HOME:-${OIH_HOME:-$(protforge_detect_home)}}"
PROTFORGE_DATA="${PROTFORGE_DATA:-${OIH_DATA:-$PROTFORGE_HOME/data}}"
PROTFORGE_MODELS="${PROTFORGE_MODELS:-${OIH_MODELS:-$PROTFORGE_HOME/models}}"
export PROTORGE_HOME PROTORGE_DATA PROTORGE_MODELS

# In-container path that $PROTFORGE_DATA is mounted at. This is a contract
# with your compose file's volume mapping, not a local path: if your compose
# mounts the data directory somewhere else, set PROTForge_MOUNT to match.
: "${PROTFORGE_MOUNT:=${OIH_MOUNT:-/data/protforge}}"

# Host Python used by the tools that run outside Docker (FreeSASA, and the
# SMILES -> .pdbqt preparation GNINA needs). Probes the new venv layout first
# and falls back to the legacy one.
protforge_host_python() {
  if [ -n "${PROTFORGE_VENV:-}" ]; then printf '%s\n' "$PROTFORGE_VENV/python.exe"; return 0; fi
  local c
  for c in "$PROTFORGE_HOME/venvs/protforge/python.exe" \
           "$PROTFORGE_HOME/venvs/oih/python.exe"; do
    if [ -f "$c" ]; then printf '%s\n' "$c"; return 0; fi
  done
  printf '%s\n' "$PROTFORGE_HOME/venvs/protforge/python.exe"
}
: "${PROTFORGE_PYTHON:=$(protforge_host_python)}"

# Locate the compose file. Prefers the legacy platform/ subdirectory layout so
# an existing $PROTFORGE_HOME resolves without moving anything.
protforge_compose_file() {
  if [ -n "${PROTFORGE_COMPOSE:-}" ]; then printf '%s\n' "$PROTFORGE_COMPOSE"; return 0; fi
  if [ -n "${OIH_COMPOSE:-}" ]; then printf '%s\n' "$OIH_COMPOSE"; return 0; fi
  local c
  for c in "$PROTFORGE_HOME/protforge-platform/docker-compose.windows.yml" \
           "$PROTFORGE_HOME/oih-platform/docker-compose.windows.yml" \
           "$PROTFORGE_HOME/protforge-platform/docker-compose.yml" \
           "$PROTFORGE_HOME/oih-platform/docker-compose.yml"; do
    if [ -f "$c" ]; then printf '%s\n' "$c"; return 0; fi
  done
  printf '%s\n' "$PROTFORGE_HOME/protforge-platform/docker-compose.windows.yml"
}
: "${PROTFORGE_COMPOSE:=$(protforge_compose_file)}"

# ---------------------------------------------------------------------------
# Containers
# ---------------------------------------------------------------------------

# All container names known to docker, running or stopped.
_protforge_containers() {
  docker ps -a --format '{{.Names}}' 2>/dev/null
}

# Resolve a canonical `protforge-<tool>` name to the container that actually
# exists. Order: explicit override (new, then legacy) > container already
# present under the canonical name > container present under the legacy
# `oih-<tool>` name > the canonical name, so compose creates a fresh one.
protforge_container() {
  local want="$1"
  local key ov legacy
  # key is the bare tool name: protforge-vina-gpu -> VINA_GPU
  key="$(printf '%s' "${want#protforge-}" | tr 'a-z-' 'A-Z_')"
  ov="$(eval "printf '%s' \"\${PROTFORGE_CONTAINER_$key:-}\"")"
  if [ -n "$ov" ]; then printf '%s\n' "$ov"; return 0; fi
  ov="$(eval "printf '%s' \"\${OIH_CONTAINER_$key:-}\"")"
  if [ -n "$ov" ]; then printf '%s\n' "$ov"; return 0; fi

  if _protforge_containers | grep -qx "$want"; then
    printf '%s\n' "$want"; return 0
  fi
  legacy="oih-${want#protforge-}"
  if [ "$legacy" != "$want" ] && _protforge_containers | grep -qx "$legacy"; then
    printf '%s\n' "$legacy"; return 0
  fi
  printf '%s\n' "$want"
}

# Translate a host (Windows/POSIX) path under $PROTFORGE_DATA to the
# in-container path.
protforge_container_path() {
  local p="$1"
  p="${p//\\//}"                       # backslashes -> slashes
  local d="${PROTFORGE_DATA//\\//}"
  d="${d/#e:/E:}"                      # normalize drive letter case
  p="${p/#e:/E:}"
  if [[ "$p" == "$d/"* ]]; then
    echo "${PROTFORGE_MOUNT%/}/${p#$d/}"
  else
    echo "$p"
  fi
}

# Ensure a container is running; start it via compose if absent.
protforge_ensure_container() {
  local want="$1"
  local name; name="$(protforge_container "$want")"
  if docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "$name"; then
    return 0
  fi
  echo "[protforge] container $name not running; starting via compose..." >&2
  docker compose -f "$PROTFORGE_COMPOSE" up -d "$name" >&2 || {
    echo "[protforge] ERROR: failed to start $name. Is Docker Desktop running and the image built?" >&2
    return 1
  }
  sleep 3
}

# docker exec with correct env for compute tools (GPU pool pick by host nvidia-smi).
protforge_exec() {
  local want="$1"; shift
  local name; name="$(protforge_container "$want")"
  protforge_ensure_container "$name" || return 1
  local gpu=""
  if command -v nvidia-smi >/dev/null 2>&1; then
    gpu=$(nvidia-smi --query-gpu=index,memory.used --format=csv,noheader,nounits \
          | sort -t, -k2 -n | head -1 | cut -d, -f1 | tr -d ' ')
  fi
  if [ -n "$gpu" ]; then
    docker exec -e "CUDA_VISIBLE_DEVICES=$gpu" "$name" "$@"
  else
    docker exec "$name" "$@"
  fi
}

# ---------------------------------------------------------------------------
# Status contract
# ---------------------------------------------------------------------------

# Success/failure markers every runner prints. An agent can rely on these two
# lines alone: a run that ends without PROTFORGE_STATUS: is a failure even if
# the script exited 0.
protforge_ok()  { echo "PROTFORGE_STATUS: OK"; }
protforge_fail() { echo "PROTFORGE_STATUS: FAIL $*"; }