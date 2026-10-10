#!/usr/bin/env bash
# vina-gpu runner: fast GPU docking of pdbqt receptor + ligand.
# NOTE: no prepare_receptor/prepare_ligand in the container — pdbqt inputs only.
set -euo pipefail
source "$(dirname "$0")/../../../scripts/_common.sh"

REC="${1:?usage: protforge-vina-gpu.sh <receptor.pdbqt> <ligand.pdbqt> <job_name> <cx> <cy> <cz>}"
LIG="${2:?missing ligand}"
JOB="${3:?missing job_name}"
CX="${4:?missing center_x}"; CY="${5:?missing center_y}"; CZ="${6:?missing center_z}"
REC="${REC//\\//}"; LIG="${LIG//\\//}"
[[ "$REC" == /* || "$REC" =~ ^[A-Za-z]:/ ]] || REC="$PROTFORGE_DATA/inputs/$REC"
[[ "$LIG" == /* || "$LIG" =~ ^[A-Za-z]:/ ]] || LIG="$PROTFORGE_DATA/inputs/$LIG"
[ -f "$REC" ] || { protforge_fail "receptor not found: $REC"; exit 1; }
[ -f "$LIG" ] || { protforge_fail "ligand not found: $LIG"; exit 1; }

OUT_HOST="$PROTFORGE_DATA/outputs/${JOB}_vina_gpu"
mkdir -p "$OUT_HOST"

# Placeholder / limitation handling for non-pdbqt inputs.
for pair in "receptor:$REC" "ligand:$LIG"; do
  KIND="${pair%%:*}"; FILE="${pair#*:}"
  if [[ "${FILE##*.}" != "pdbqt" ]]; then
    cp -f "$FILE" "$OUT_HOST/"
    echo "[protforge] WARNING: $KIND is not .pdbqt ($FILE). No prepare_receptor in the"
    echo "[protforge] container — convert with ADFR/ADT (e.g. 'prepare_receptor -r x.pdb')"
    echo "[protforge] and pass the .pdbqt. The original file was copied to the output dir"
    echo "[protforge] as a placeholder only."
    protforge_fail "$KIND must be pdbqt (conversion tools not in image)"
    exit 1
  fi
done

C_REC="$(protforge_container_path "$REC")"
C_LIG="$(protforge_container_path "$LIG")"
C_OUT="$(protforge_container_path "$OUT_HOST")"

# Try GPU build first; fall back to CPU AutoDock Vina when the container has no
# NVIDIA OpenCL platform (e.g. Docker Desktop on WSL2 does not expose OpenCL).
if ! protforge_exec protforge-vina-gpu vina_gpu --receptor "$C_REC" --ligand "$C_LIG" \
  --out "$C_OUT/docked.pdbqt" \
  --center_x "$CX" --center_y "$CY" --center_z "$CZ" \
  --size_x 25 --size_y 25 --size_z 25 \
  --thread 8000 --num_modes 9; then
  echo "[protforge] vina_gpu failed (likely no NVIDIA OpenCL on this host) —" >&2
  echo "[protforge] falling back to CPU AutoDock Vina 1.2.3 (same scoring)" >&2
  protforge_exec protforge-vina-gpu vina --receptor "$C_REC" --ligand "$C_LIG" \
    --out "$C_OUT/docked.pdbqt" \
    --center_x "$CX" --center_y "$CY" --center_z "$CZ" \
    --size_x 25 --size_y 25 --size_z 25 \
    --num_modes 9 --exhaustiveness 8
fi

OUT_PDBQT="$OUT_HOST/docked.pdbqt"
if [ -s "$OUT_PDBQT" ]; then
  POSES=$(grep -c '^MODEL' "$OUT_PDBQT" || true)
  BEST=$(grep -m1 'VINA RESULT' "$OUT_PDBQT" || true)
  echo "PROTFORGE_OUTPUT_DIR: $OUT_HOST"
  echo "PROTFORGE_OUTPUT_PDBQT: $OUT_HOST/docked.pdbqt"
  echo "PROTFORGE_POSES: $POSES"
  echo "PROTFORGE_BEST: $BEST"
  protforge_ok
else
  protforge_fail "vina_gpu produced no docked.pdbqt"
  exit 1
fi
