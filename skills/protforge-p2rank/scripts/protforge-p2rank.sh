#!/usr/bin/env bash
# p2rank runner: ML binding pocket prediction.
# First run loads the Java ML model (~6 min); subsequent runs are fast.
set -euo pipefail
source "$(dirname "$0")/../../../scripts/_common.sh"

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
