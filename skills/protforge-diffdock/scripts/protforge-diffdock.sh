#!/usr/bin/env bash
# diffdock runner: diffusion-model docking from receptor PDB + ligand SMILES.
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

REC="${1:?usage: protforge-diffdock.sh <receptor_pdb> <smiles> <job_name>}"
SMILES="${2:?missing smiles}"
JOB="${3:?missing job_name}"
REC="${REC//\\//}"
[[ "$REC" == /* || "$REC" =~ ^[A-Za-z]:/ ]] || REC="$PROTFORGE_DATA/inputs/$REC"
[ -f "$REC" ] || { protforge_fail "receptor not found: $REC"; exit 1; }

OUT_HOST="$PROTFORGE_DATA/outputs/${JOB}_diffdock"
mkdir -p "$OUT_HOST"
CSV_HOST="$PROTFORGE_DATA/inputs/${JOB}_diffdock.csv"
C_REC="$(protforge_container_path "$REC")"

# DiffDock input CSV: complex_name,protein_path,ligand_description,protein_sequence
printf 'complex_name,protein_path,ligand_description,protein_sequence\n%s,%s,%s,\n' \
  "$JOB" "$C_REC" "$SMILES" > "$CSV_HOST"
C_CSV="$(protforge_container_path "$CSV_HOST")"
C_OUT="$(protforge_container_path "$OUT_HOST")"

# First run precomputes SO(2)/SO(3) caches (persisted in /root/.cache); a normal
# run takes a few minutes on GPU.
protforge_exec protforge-diffdock python3 /app/DiffDock/inference.py \
  --protein_ligand_csv "$C_CSV" --out_dir "$C_OUT"

N_SDF=$(find "$OUT_HOST" -name '*.sdf' 2>/dev/null | wc -l | tr -d ' ')
if [ "$N_SDF" -gt 0 ]; then
  BEST=$(find "$OUT_HOST" -name 'rank*_confidence*.sdf' -printf '%f\n' 2>/dev/null \
         | sed -E 's/rank[0-9]+_confidence(-?[0-9.]+)\.sdf/\1/' \
         | sort -g | tail -1)
  echo "PROTFORGE_OUTPUT_DIR: $OUT_HOST"
  echo "PROTFORGE_POSES: $N_SDF"
  echo "PROTFORGE_BEST_CONFIDENCE: $BEST"
  protforge_ok
else
  protforge_fail "diffdock produced no sdf poses"
  exit 1
fi
