#!/usr/bin/env bash
# gnina runner: deep-learning docking of a SMILES ligand into a receptor PDB.
# Ligand 3D SDF is generated on the host with RDKit (gnina reads SDF directly).
set -euo pipefail
source "$(dirname "$0")/../../../scripts/_common.sh"

REC="${1:?usage: protforge-gnina.sh <receptor_pdb> <smiles> <job_name> [cx cy cz box_size]}"
SMILES="${2:?missing smiles}"
JOB="${3:?missing job_name}"
CX="${4:-0}"; CY="${5:-0}"; CZ="${6:-0}"; BOX="${7:-25}"
REC="${REC//\\//}"
if [[ ! "$REC" == /* && ! "$REC" =~ ^[A-Za-z]:/ ]]; then
  REC="$PROTFORGE_DATA/inputs/$REC"
fi
[ -f "$REC" ] || { protforge_fail "receptor not found: $REC"; exit 1; }

OUT_HOST="$PROTFORGE_DATA/outputs/${JOB}_gnina"
mkdir -p "$OUT_HOST"
LIG_HOST="$PROTFORGE_DATA/inputs/${JOB}_ligand.sdf"

# Build 3D ligand SDF from SMILES with RDKit on the host.
"$PROTFORGE_PYTHON" - "$SMILES" "$LIG_HOST" <<'PY'
import sys
from rdkit import Chem
from rdkit.Chem import AllChem
smiles, out = sys.argv[1], sys.argv[2]
m = Chem.MolFromSmiles(smiles)
if m is None:
    sys.exit("PROTFORGE_STATUS: FAIL invalid SMILES: %s" % smiles)
m = Chem.AddHs(m)
AllChem.EmbedMolecule(m, AllChem.ETKDGv3())
AllChem.MMFFOptimizeMolecule(m)
w = Chem.SDWriter(out)
w.write(m)
w.close()
print("PROTFORGE_LIGAND_ATOMS: %d" % m.GetNumAtoms())
PY
[ -f "$LIG_HOST" ] || { protforge_fail "ligand SDF generation failed"; exit 1; }

C_REC="$(protforge_container_path "$REC")"
C_LIG="$(protforge_container_path "$LIG_HOST")"
C_OUT="$(protforge_container_path "$OUT_HOST")"

protforge_exec protforge-gnina gnina --receptor "$C_REC" --ligand "$C_LIG" \
  --out "$C_OUT/docked.sdf" \
  --center_x "$CX" --center_y "$CY" --center_z "$CZ" \
  --size_x "$BOX" --size_y "$BOX" --size_z "$BOX" \
  --num_modes 9 --exhaustiveness 8

SDF="$OUT_HOST/docked.sdf"
if [ -s "$SDF" ]; then
  POSES=$(grep -c '^\$\$\$\$' "$SDF" || true)
  AFF=$(awk '/minimizedAffinity/{getline; print; exit}' "$SDF")
  CNN=$(awk '/> <CNNscore>/{getline; print; exit}' "$SDF")
  echo "PROTFORGE_OUTPUT_DIR: $OUT_HOST"
  echo "PROTFORGE_OUTPUT_SDF: $OUT_HOST/docked.sdf"
  echo "PROTFORGE_POSES: $POSES"
  echo "PROTFORGE_BEST_AFFINITY: $AFF"
  echo "PROTFORGE_BEST_CNN_SCORE: $CNN"
  protforge_ok
else
  protforge_fail "gnina produced no docked.sdf"
  exit 1
fi
