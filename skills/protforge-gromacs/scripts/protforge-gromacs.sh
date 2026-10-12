#!/usr/bin/env bash
# gromacs runner: single-protein MD pipeline
#   pdb2gmx -> editconf -> solvate -> genion -> em -> nvt -> npt -> md
# Protein-only scope (no acpype/ligand parametrization).
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

PDB="${1:?usage: protforge-gromacs.sh <pdb_path> <job_name> [steps]}"
JOB="${2:?missing job_name}"
STEPS="${3:-5000}"
PDB="${PDB//\\//}"
[[ "$PDB" == /* || "$PDB" =~ ^[A-Za-z]:/ ]] || PDB="$PROTFORGE_DATA/inputs/$PDB"
[ -f "$PDB" ] || { protforge_fail "input not found: $PDB"; exit 1; }

REF_DIR="$(cd "$(dirname "$0")/../references" && pwd)"
OUT_HOST="$PROTFORGE_DATA/outputs/${JOB}_gromacs"
mkdir -p "$OUT_HOST"
cp -f "$PDB" "$OUT_HOST/"
STEM="$(basename "$PDB")"; STEM="${STEM%.*}"
cp -f "$REF_DIR"/*.mdp "$OUT_HOST/"
# Replace nsteps in the three dynamics mdps with $STEPS (keep em at default).
sed -i -E "s/^nsteps[[:space:]]*=.*/nsteps                  = $STEPS/" \
  "$OUT_HOST/nvt.mdp" "$OUT_HOST/npt.mdp" "$OUT_HOST/md.mdp"

C_OUT="$(protforge_container_path "$OUT_HOST")"

protforge_exec protforge-gromacs bash -lc "
set -e
cd '$C_OUT'
gmx pdb2gmx -f '$STEM.pdb' -o processed.gro -p topol.top -ff charmm27 -water tip3p < /dev/null
gmx editconf -f processed.gro -o boxed.gro -c -d 1.0 -bt cubic
gmx solvate -cp boxed.gro -cs /usr/share/gromacs/top/spc216.gro -o solvated.gro -p topol.top
gmx grompp -f ions.mdp -c solvated.gro -p topol.top -o ions.tpr -maxwarn 1
echo SOL | gmx genion -s ions.tpr -o ionized.gro -p topol.top -pname NA -nname CL -neutral
gmx grompp -f em.mdp -c ionized.gro -p topol.top -o em.tpr -maxwarn 1
gmx mdrun -deffnm em
gmx grompp -f nvt.mdp -c em.gro -r em.gro -p topol.top -o nvt.tpr -maxwarn 1
gmx mdrun -deffnm nvt
gmx grompp -f npt.mdp -c nvt.gro -r nvt.gro -t nvt.cpt -p topol.top -o npt.tpr -maxwarn 1
gmx mdrun -deffnm npt
gmx grompp -f md.mdp -c npt.gro -t npt.cpt -p topol.top -o md.tpr -maxwarn 1
gmx mdrun -deffnm md
"

for f in md.gro md.tpr md.xtc em.log; do
  [ -s "$OUT_HOST/$f" ] || { protforge_fail "missing $f after pipeline"; exit 1; }
done
POT=$(grep 'Potential Energy' "$OUT_HOST/em.log" | tail -1 | sed 's/^ *//')
NATOMS=$(grep -m1 -E 'There are:[[:space:]]+[0-9]+ Atoms' "$OUT_HOST/md.log" | awk '{print $3}' || true)
echo "PROTFORGE_OUTPUT_DIR: $OUT_HOST"
echo "PROTFORGE_FINAL_GRO: $OUT_HOST/md.gro"
echo "PROTFORGE_FINAL_TPR: $OUT_HOST/md.tpr"
echo "PROTFORGE_FINAL_XTC: $OUT_HOST/md.xtc"
echo "PROTFORGE_EM_POTENTIAL: $POT"
echo "PROTFORGE_ATOMS: $NATOMS"
protforge_ok
