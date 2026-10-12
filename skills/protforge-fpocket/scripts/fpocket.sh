#!/usr/bin/env bash
# fpocket runner: detect pockets in a protein structure.
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

PDB="${1:?usage: fpocket.sh <pdb_path>}"
PDB="${PDB//\\//}"
if [[ ! "$PDB" == /* && ! "$PDB" =~ ^[A-Za-z]:/ ]]; then
  PDB="$PROTFORGE_DATA/inputs/$PDB"
fi
[ -f "$PDB" ] || { echo "PROTFORGE_STATUS: FAIL input not found: $PDB"; exit 1; }

STEM="$(basename "$PDB")"; STEM="${STEM%.*}"
OUT_HOST="$PROTFORGE_DATA/outputs/fpocket_$STEM"
mkdir -p "$OUT_HOST"
cp -f "$PDB" "$OUT_HOST/"

C_OUT="$(protforge_container_path "$OUT_HOST")"
C_NAME="$(basename "$OUT_HOST")"

protforge_exec protforge-fpocket fpocket -f "$C_OUT/$STEM.pdb" -m 3.0
# fpocket writes <stem>_out/ next to the input file
if [ -d "$OUT_HOST/${STEM}_out" ]; then
  N=$(grep -c "^Pocket [0-9]" "$OUT_HOST/${STEM}_out/${STEM}_info.txt" 2>/dev/null || echo 0)
  echo "PROTFORGE_OUTPUT_DIR: $OUT_HOST/${STEM}_out"
  echo "PROTFORGE_POCKETS: $N"
  protforge_ok
else
  protforge_fail "fpocket produced no output"
  exit 1
fi
