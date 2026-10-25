#!/usr/bin/env bash
# clash runner: 碰撞检测与几何校验（cKDTree，O(n log n)）。
# Runs on the HOST python (no docker): <data-root>\venvs\protforge\python.exe
set -euo pipefail
# Locate the shared helper. A plugin install resolves ../../../scripts/, but
# a standalone skills install (~/.minimax/skills/<skill>/scripts) has no such
# parent, so fall back to the installed plugin tree before giving up.
__pf_lib=""
for __pf_c in "$(dirname "$0")/../../../scripts/_common.sh" \
              "$HOME/.minimax/plugins/protforge/scripts/_common.sh"; do
  if [ -f "$__pf_c" ]; then __pf_lib="$__pf_c"; break; fi
done
if [ -z "$__pf_lib" ]; then
  echo "PROTFORGE_STATUS: FAIL cannot locate scripts/_common.sh" >&2
  exit 1
fi
source "$__pf_lib"
unset __pf_lib __pf_c

PDB="${1:?usage: clash.sh <pdb_path> [job_name] [mode] [threshold]}"
JOB="${2:-clash}"
MODE="${3:-report}"
THRESHOLD="${4:-2.0}"
PDB="${PDB//\\//}"
[[ "$PDB" == /* || "$PDB" =~ ^[A-Za-z]:/ ]] || PDB="$PROTFORGE_DATA/inputs/$PDB"
[ -f "$PDB" ] || { protforge_fail "input not found: $PDB"; exit 1; }

OUT_HOST="$PROTFORGE_DATA/outputs/${JOB}_clash"
mkdir -p "$OUT_HOST"
cp -f "$PDB" "$OUT_HOST/"

if [ "$MODE" = "repair" ]; then
  REPAIRED="$OUT_HOST/${JOB}_repaired.pdb"
else
  REPAIRED=""
fi

if ! "$PROTFORGE_PYTHON" "$(dirname "$0")/clash.py" \
      --input "$PDB" \
      --mode "$MODE" \
      --threshold "$THRESHOLD" \
      --json "$OUT_HOST/clash_report.json" \
      ${REPAIRED:+--output "$REPAIRED"}; then
  protforge_fail "clash.py 执行失败"
  exit 1
fi

echo "PROTFORGE_OUTPUT_DIR: $OUT_HOST"
echo "PROTFORGE_CLASHES: $(python -c "import json,sys;print(json.load(open(sys.argv[1]))['n_clashes'])" "$OUT_HOST/clash_report.json" 2>/dev/null || echo -1)"
protforge_ok
