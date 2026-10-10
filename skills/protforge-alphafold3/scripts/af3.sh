#!/usr/bin/env bash
# AlphaFold 3 runner: single-chain protein, one seed.
set -euo pipefail
source "$(dirname "$0")/../../../scripts/_common.sh"

JOB="${1:?usage: af3.sh <job_name> <protein_sequence> [n_cpu]}"
SEQ="${2:?missing protein sequence}"
SEQ="$(echo "$SEQ" | tr -d '[:space:]')"
# jackhmmer spawns 4 parallel DB scans, each using n_cpu threads.
# Default 4 → 16 threads total, sized for a 12-CPU Docker Desktop VM;
# raise on bigger hosts (e.g. 8 → 32 threads).
NCPU="${3:-4}"

IN_HOST="$PROTFORGE_DATA/inputs/${JOB}_af3"
OUT_HOST="$PROTFORGE_DATA/outputs/${JOB}_af3"
mkdir -p "$IN_HOST" "$OUT_HOST"

cat > "$IN_HOST/${JOB}_af3.json" <<JSON
{
  "name": "$JOB",
  "sequences": [{"protein": {"id": ["A"], "sequence": "$SEQ"}}],
  "modelSeeds": [1],
  "dialect": "alphafold3",
  "version": 2
}
JSON

C_IN="$(protforge_container_path "$IN_HOST")"
C_OUT="$(protforge_container_path "$OUT_HOST")"

echo "[protforge] AF3 job $JOB (${#SEQ} aa) — input: $IN_HOST/${JOB}_af3.json"
protforge_exec protforge-alphafold3 python /app/alphafold/run_alphafold.py \
  --json_path="$C_IN/${JOB}_af3.json" \
  --output_dir="$C_OUT" \
  --model_dir=/data/alphafold3_models \
  --db_dir=/data/alphafold3_db \
  --flash_attention_implementation=triton \
  --jackhmmer_n_cpu="$NCPU" --nhmmer_n_cpu="$NCPU"

CIF=$(find "$OUT_HOST" -name "*_model.cif" | head -1)
if [ -n "$CIF" ]; then
  echo "PROTFORGE_CIF: $CIF"
  CONF=$(find "$OUT_HOST" -name "*summary_confidences*.json" | head -1)
  [ -n "$CONF" ] && echo "PROTFORGE_CONFIDENCES: $CONF"
  protforge_ok
else
  protforge_fail "no model cif produced"
  exit 1
fi
