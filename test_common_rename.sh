#!/usr/bin/env bash
# Fixture for scripts/_common.sh — checks the rename compatibility layer.
# Fast, synthetic, no real docker: a stub `docker` on PATH answers `ps`.
# Run:  bash test_common_rename.sh
set -uo pipefail

COMMON="$(cd "$(dirname "$0")" && pwd)/scripts/_common.sh"
[ -f "$COMMON" ] || { echo "FAIL: cannot find $COMMON"; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
cat > "$TMP/docker" <<'STUB'
#!/usr/bin/env bash
if [ "${1:-}" = "ps" ]; then
  [ -n "${FAKE_CONTAINERS:-}" ] && printf '%s\n' $FAKE_CONTAINERS
  exit 0
fi
exit 0
STUB
chmod +x "$TMP/docker"
export PATH="$TMP:$PATH"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL %s   (got: %s / want: %s)\n' "$1" "$2" "$3"; }
eq()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "$2" "$3"; fi; }

# run <shell snippet> [ENV=V ...] — snippet runs in a subshell with _common.sh sourced
run() {
  local probe="$1"; shift
  env "$@" bash -c "source '$COMMON' >/dev/null 2>&1; $probe"
}

echo "== data root resolution =="
eq "legacy OIH_HOME is honoured" \
   "$(run 'echo "$PROTFORGE_HOME"' OIH_HOME=X:/root)" "X:/root"
eq "explicit PROTFORGE_HOME wins" \
   "$(run 'echo "$PROTFORGE_HOME"' OIH_HOME=X:/root PROTFORGE_HOME=X:/custom)" "X:/custom"
eq "legacy OIH_DATA is honoured" \
   "$(run 'echo "$PROTFORGE_DATA"' OIH_HOME=X:/root OIH_DATA=X:/root/other)" "X:/root/other"
eq "PROTFORGE_DATA derives from home" \
   "$(run 'echo "$PROTFORGE_DATA"' OIH_HOME=X:/root)" "X:/root/data"
eq "PROTFORGE_MODELS derives from home" \
   "$(run 'echo "$PROTFORGE_MODELS"' OIH_HOME=X:/root)" "X:/root/models"

echo "== compose file discovery =="
# NOTE: these cases drive the root through $OIH_HOME rather than
# $PROTFORGE_HOME. On the Git Bash build used for testing, the PROTORGE_*
# variables cannot be injected into a child process via `env` or `export`
# (only a command-prefix assignment works), whereas OIH_HOME propagates
# normally. The legacy name is also the path these cases are meant to cover.
LEGACY_PLATFORM_ROOT="$TMP/legacy-platform-root"
mkdir -p "$LEGACY_PLATFORM_ROOT/oih-platform"
touch "$LEGACY_PLATFORM_ROOT/oih-platform/docker-compose.windows.yml"
eq "finds the legacy oih-platform layout under a legacy home" \
   "$(run 'echo "$PROTFORGE_COMPOSE"' OIH_HOME="$LEGACY_PLATFORM_ROOT")" \
   "$LEGACY_PLATFORM_ROOT/oih-platform/docker-compose.windows.yml"
eq "explicit PROTFORGE_COMPOSE wins" \
   "$(run 'echo "$PROTFORGE_COMPOSE"' PROTFORGE_COMPOSE=X:/x/dc.yml)" "X:/x/dc.yml"
eq "falls back to the protforge-platform default when nothing exists" \
   "$(run 'echo "$PROTFORGE_COMPOSE"' OIH_HOME=X:/no-such-dir)" \
   "X:/no-such-dir/protforge-platform/docker-compose.windows.yml"

echo "== container name resolution =="
eq "legacy oih-* container is found and reused" \
   "$(run 'protforge_container protforge-vina-gpu' FAKE_CONTAINERS='oih-vina-gpu oih-esm')" "oih-vina-gpu"
eq "canonical protforge-* container is used when present" \
   "$(run 'protforge_container protforge-esm' FAKE_CONTAINERS='protforge-esm oih-vina-gpu')" "protforge-esm"
eq "canonical name wins over legacy when both exist" \
   "$(run 'protforge_container protforge-esm' FAKE_CONTAINERS='protforge-esm oih-esm')" "protforge-esm"
eq "unknown container resolves to the canonical name" \
   "$(run 'protforge_container protforge-brandnew' FAKE_CONTAINERS='oih-esm')" "protforge-brandnew"
eq "PROTFORGE_CONTAINER_<TOOL> override wins" \
   "$(run 'protforge_container protforge-vina-gpu' PROTFORGE_CONTAINER_VINA_GPU=my-vina)" "my-vina"
eq "legacy OIH_CONTAINER_<TOOL> override still honoured" \
   "$(run 'protforge_container protforge-vina-gpu' OIH_CONTAINER_VINA_GPU=old-vina)" "old-vina"
eq "PROTFORGE_ override beats the legacy one" \
   "$(run 'protforge_container protforge-vina-gpu' PROTFORGE_CONTAINER_VINA_GPU=new OIH_CONTAINER_VINA_GPU=old)" "new"

echo "== container path translation =="
eq "host data root maps to the default mount point" \
   "$(run 'protforge_container_path "X:/root/data/inputs/x.pdb"' OIH_HOME=X:/root)" "/data/protforge/inputs/x.pdb"
eq "legacy OIH_MOUNT is honoured for pre-rename deployments" \
   "$(run 'protforge_container_path "X:/root/data/inputs/x.pdb"' OIH_HOME=X:/root OIH_MOUNT=/data/oih)" \
   "/data/oih/inputs/x.pdb"
eq "PROTFORGE_MOUNT override changes the mount point" \
   "$(run 'protforge_container_path "X:/root/data/inputs/x.pdb"' OIH_HOME=X:/root PROTFORGE_MOUNT=/mnt/data)" \
   "/mnt/data/inputs/x.pdb"
eq "lowercase drive letter is normalised" \
   "$(run 'protforge_container_path "x:/root/data/inputs/x.pdb"' OIH_HOME=X:/root)" "/data/protforge/inputs/x.pdb"
eq "backslashes are normalised" \
   "$(run 'protforge_container_path "X:\root\data\inputs\x.pdb"' OIH_HOME=X:/root)" "/data/protforge/inputs/x.pdb"
eq "path outside the data root passes through untouched" \
   "$(run 'protforge_container_path "X:/root/models/w.pth"' OIH_HOME=X:/root)" "X:/root/models/w.pth"
eq "trailing slash on PROTFORGE_MOUNT does not double up" \
   "$(run 'protforge_container_path "X:/root/data/a.pdb"' OIH_HOME=X:/root PROTFORGE_MOUNT=/mnt/data/)" \
   "/mnt/data/a.pdb"

echo "== host python resolution =="
eq "default points at the new venv layout" \
   "$(run 'echo "$PROTFORGE_PYTHON"' OIH_HOME=X:/no-such-dir)" "X:/no-such-dir/venvs/protforge/python.exe"
# Build a real legacy venv layout under $TMP instead of pointing at whatever
# happens to exist on the machine running the tests.
LEGACY_ROOT="$TMP/legacy-root"
mkdir -p "$LEGACY_ROOT/venvs/oih"
touch "$LEGACY_ROOT/venvs/oih/python.exe"
eq "legacy venv is found and reused" \
   "$(run 'echo "$PROTFORGE_PYTHON"' OIH_HOME="$LEGACY_ROOT")" "$LEGACY_ROOT/venvs/oih/python.exe"
eq "explicit PROTForge_VENV wins" \
   "$(run 'echo "$PROTFORGE_PYTHON"' OIH_HOME=X:/root PROTForge_UNUSED=1 PROTForge_X=1 PROTFORGE_VENV=X:/custom/venv)" \
   "X:/custom/venv/python.exe"

echo "== status contract =="
eq "protforge_ok"  "$(run 'protforge_ok' OIH_HOME=X:/root)"  "PROTFORGE_STATUS: OK"
eq "protforge_fail" "$(run 'protforge_fail nope' OIH_HOME=X:/root)" "PROTFORGE_STATUS: FAIL nope"

echo "== legacy names are gone =="
eq "no oih_ok function remains" \
   "$(run 'if declare -f oih_ok >/dev/null 2>&1; then echo present; else echo absent; fi' OIH_HOME=X:/root)" "absent"
eq "no oih_exec function remains" \
   "$(run 'if declare -f oih_exec >/dev/null 2>&1; then echo present; else echo absent; fi' OIH_HOME=X:/root)" "absent"
eq "no oih_container_path function remains" \
   "$(run 'if declare -f oih_container_path >/dev/null 2>&1; then echo present; else echo absent; fi' OIH_HOME=X:/root)" "absent"

echo ""
echo "passed=$PASS failed=$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
echo "ALL GREEN"