#!/usr/bin/env bash
# discotope3 runner: B-cell epitope prediction.
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

# args: pdb_path [job_name] [threshold] [multichain]
PDB="${1:?usage: discotope3.sh <pdb_path> [job_name] [threshold] [multichain]}"
JOB="${2:-}"
THRESHOLD="${3:-0.5}"
MULTICHAIN="${4:-false}"

PDB="${PDB//\\//}"
if [[ "$PDB" =~ ^/([A-Za-z])/(.*)$ ]]; then
  PDB="${BASH_REMATCH[1]^}:/${BASH_REMATCH[2]}"   # /e/protforge/... -> <data-root>/...
fi
if [[ ! "$PDB" =~ ^[A-Za-z]:/ ]]; then
  PDB="$PROTFORGE_DATA/inputs/$PDB"
fi
[ -f "$PDB" ] || { protforge_fail "input not found: $PDB"; exit 1; }

STEM="$(basename "$PDB")"; STEM="${STEM%.*}"
JOB="${JOB:-$STEM}"
OUT_HOST="$PROTFORGE_DATA/outputs/${JOB}_discotope3"
mkdir -p "$OUT_HOST"

C_OUT="$(protforge_container_path "$OUT_HOST")"
C_PDB="$(protforge_container_path "$PDB")"

protforge_ensure_container protforge-discotope3 || { protforge_fail "container protforge-discotope3 unavailable"; exit 1; }
name="$(protforge_container protforge-discotope3)"

EXTRA=()
if [ "$MULTICHAIN" = "true" ]; then
  EXTRA+=(--multichain_mode)
fi

# main.py must run with /app/discotope3/discotope3 as working directory.
docker exec -w /app/discotope3/discotope3 "$name" python3 -u main.py \
  --pdb_or_zip_file "$C_PDB" \
  --out_dir "$C_OUT" \
  --models_dir /app/discotope3/models \
  --struc_type solved \
  --calibrated_score_epi_threshold "$THRESHOLD" \
  "${EXTRA[@]}"

# summarize produced files; main.py logs tracebacks but may still exit 0,
# so treat a traceback in log.txt or a missing per-residue CSV as failure.
# Output layout: <out>/<input_stem>/<chain>_discotope3.csv (one CSV per chain).
if grep -q "Traceback (most recent call last)" "$OUT_HOST"/log.txt 2>/dev/null; then
  echo "PROTFORGE_OUTPUT_DIR: $OUT_HOST"
  protforge_fail "discotope3 errored (see log.txt)"
  exit 1
fi

CSV=$(find "$OUT_HOST" -name "*_discotope3.csv" 2>/dev/null | head -1 || true)
echo "PROTFORGE_OUTPUT_DIR: $OUT_HOST"
echo "PROTFORGE_OUTPUT_FILES:"
find "$OUT_HOST" -type f | sort || true
if [ -z "$CSV" ]; then
  protforge_fail "discotope3 produced no per-residue CSV"
  exit 1
fi
# count residues flagged as epitope (epitope column == True) across all chain CSVs
N=$(find "$OUT_HOST" -name "*_discotope3.csv" -exec cat {} + 2>/dev/null | awk -F, 'NR>1 && $7=="True"' | wc -l)
echo "PROTFORGE_EPI_CSV: $CSV"
echo "PROTFORGE_EPI_RESIDUES: $N"
protforge_ok
