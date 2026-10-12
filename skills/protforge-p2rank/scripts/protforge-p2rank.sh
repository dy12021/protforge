#!/usr/bin/env bash
# p2rank runner: ML binding pocket prediction.
# First run loads the Java ML model (~6 min); subsequent runs are fast.
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

PDB="${1:?usage: protforge-p2rank.sh <pdb_path> <job_name>}"
JOB="${2:-p2rank}"
PDB="${PDB//\\//}"
if [[ ! "$PDB" == /* && ! "$PDB" =~ ^[A-Za-z]:/ ]]; then
  PDB="$PROTFORGE_DATA/inputs/$PDB"
fi
[ -f "$PDB" ] || { protforge_fail "input not found: $PDB"; exit 1; }

OUT_HOST="$PROTFORGE_DATA/outputs/${JOB}_p2rank"
mkdir -p "$OUT_HOST"
cp -f "$PDB" "$OUT_HOST/"
STEM="$(basename "$PDB")"; STEM="${STEM%.*}"

C_OUT="$(protforge_container_path "$OUT_HOST")"

protforge_exec protforge-p2rank /app/p2rank/prank predict -f "$C_OUT/$STEM.pdb" -o "$C_OUT"

CSV="$OUT_HOST/${STEM}.pdb_predictions.csv"
if [ -f "$CSV" ]; then
  echo "PROTFORGE_OUTPUT_DIR: $OUT_HOST"
  echo "PROTFORGE_TOP_POCKETS:"
  head -n 4 "$CSV"
  protforge_ok
else
  protforge_fail "p2rank produced no predictions csv"
  exit 1
fi
