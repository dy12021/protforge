#!/usr/bin/env bash
# proteinmpnn runner: design sequences for a protein backbone.
set -euo pipefail
source "$(dirname "$0")/../../../scripts/_common.sh"

# args: pdb_path [chains] [num_sequences] [sampling_temp] [job_name]
PDB="${1:?usage: proteinmpnn.sh <pdb_path> [chains] [num_sequences] [sampling_temp] [job_name]}"
CHAINS="${2:-A}"
NUM_SEQ="${3:-8}"
TEMP="${4:-0.1}"
JOB="${5:-}"

PDB="${PDB//\\//}"
if [[ "$PDB" =~ ^/([A-Za-z])/(.*)$ ]]; then
  PDB="${BASH_REMATCH[1]^}:/${BASH_REMATCH[2]}"   # /e/protforge/... -> E:/protforge/...
fi
if [[ ! "$PDB" =~ ^[A-Za-z]:/ ]]; then
  PDB="$PROTFORGE_DATA/inputs/$PDB"
fi
[ -f "$PDB" ] || { protforge_fail "input not found: $PDB"; exit 1; }

STEM="$(basename "$PDB")"; STEM="${STEM%.*}"
JOB="${JOB:-$STEM}"
OUT_HOST="$PROTFORGE_DATA/outputs/${JOB}_proteinmpnn"
mkdir -p "$OUT_HOST"
cp -f "$PDB" "$OUT_HOST/"

C_OUT="$(protforge_container_path "$OUT_HOST")"
C_PDB="$(protforge_container_path "$PDB")"

protforge_exec protforge-proteinmpnn python3 /app/ProteinMPNN/protein_mpnn_run.py \
  --pdb_path "$C_PDB" \
  --out_folder "$C_OUT" \
  --num_seq_per_target "$NUM_SEQ" \
  --sampling_temp "$TEMP" \
  --pdb_path_chains "$CHAINS" \
  --batch_size 1

FA=$(ls "$OUT_HOST"/seqs/*.fa 2>/dev/null | head -1 || true)
if [ -n "$FA" ]; then
  N=$(grep -c "^>" "$FA" || true)
  echo "PROTFORGE_OUTPUT_DIR: $OUT_HOST"
  echo "PROTFORGE_FASTA: $FA"
  echo "PROTFORGE_SEQUENCES: $N"
  protforge_ok
else
  protforge_fail "proteinmpnn produced no FASTA output"
  exit 1
fi
