#!/usr/bin/env bash
# chemprop runner: ADMET property prediction from SMILES (default ESOL model).
set -euo pipefail
source "$(dirname "$0")/../../../scripts/_common.sh"

JOB="${1:?usage: protforge-chemprop.sh <job_name> <smiles,csv> [model_path]}"
SMILES="${2:?missing smiles (comma-separated)}"
MODEL_IN="${3:-$PROTFORGE_MOUNT/models/admet/models/esol/model_0/best.pt}"
# Accept container paths as-is; map host paths under $PROTFORGE_MODELS to $PROTFORGE_MOUNT/models/.
M="${MODEL_IN//\\//}"
D="${PROTFORGE_MODELS//\\//}"
if [[ "$M" == "$D/"* ]]; then
  MODEL="$PROTFORGE_MOUNT/models/${M#"$D"/}"
elif [[ "$M" == /* ]]; then
  MODEL="$M"
else
  protforge_fail "model must be a container path or a path under $PROTFORGE_MODELS"
  exit 1
fi

OUT_HOST="$PROTFORGE_DATA/outputs/${JOB}_chemprop"
mkdir -p "$OUT_HOST"
CSV_HOST="$PROTFORGE_DATA/inputs/${JOB}_smiles.csv"
C_CSV="$(protforge_container_path "$CSV_HOST")"
C_OUT="$(protforge_container_path "$OUT_HOST")"

# chemprop v2 expects a csv with a 'smiles' column.
{ echo "smiles"; tr ',' '\n' <<< "$SMILES"; } > "$CSV_HOST"

protforge_exec protforge-chemprop python3 -m chemprop.cli.predict \
  --test-path "$C_CSV" \
  --model-path "$MODEL" \
  --preds-path "$C_OUT/preds.csv" \
  --accelerator cpu

if [ -s "$OUT_HOST/preds.csv" ]; then
  echo "PROTFORGE_OUTPUT_DIR: $OUT_HOST"
  echo "PROTFORGE_PREDS_CSV: $OUT_HOST/preds.csv"
  echo "PROTFORGE_PREDS:"
  cat "$OUT_HOST/preds.csv"
  protforge_ok
else
  protforge_fail "chemprop produced no preds.csv"
  exit 1
fi
