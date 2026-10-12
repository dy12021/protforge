#!/usr/bin/env bash
# freesasa runner: per-residue SASA + ADC conjugation site candidates.
# Runs on the HOST python (no docker): <data-root>\venvs\protforge\python.exe
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

PDB="${1:?usage: protforge-freesasa.sh <pdb_path> <job_name>}"
JOB="${2:-freesasa}"
PDB="${PDB//\\//}"
[[ "$PDB" == /* || "$PDB" =~ ^[A-Za-z]:/ ]] || PDB="$PROTFORGE_DATA/inputs/$PDB"
[ -f "$PDB" ] || { protforge_fail "input not found: $PDB"; exit 1; }

OUT_HOST="$PROTFORGE_DATA/outputs/${JOB}_freesasa"
mkdir -p "$OUT_HOST"

"$PROTFORGE_PYTHON" - "$PDB" "$OUT_HOST" <<'PY'
import sys, json
import freesasa

pdb, out_dir = sys.argv[1], sys.argv[2]
structure = freesasa.Structure(pdb)
result = freesasa.calc(structure)

per_res = []
for chain, residues in result.residueAreas().items():
    for res_key, area in residues.items():
        per_res.append({
            "chain": chain,
            "residue": area.residueType if hasattr(area, "residueType") else res_key[:3],
            "resnum": area.residueNumber if hasattr(area, "residueNumber") else res_key[3:],
            "sasa": round(area.total, 2),
        })

per_res.sort(key=lambda r: (r["chain"], int(str(r["resnum"]))))
with open(f"{out_dir}/sasa_per_residue.json", "w") as fh:
    json.dump(per_res, fh, indent=2)

TARGETS = {"LYS", "CYS", "THR", "SER"}
cands = [r for r in per_res if str(r["residue"]).upper() in TARGETS and r["sasa"] > 80.0]
cands.sort(key=lambda r: -r["sasa"])
with open(f"{out_dir}/adc_candidates.json", "w") as fh:
    json.dump(cands, fh, indent=2)

print("PROTFORGE_RESIDUES: %d" % len(per_res))
print("PROTFORGE_CANDIDATES: %d" % len(cands))
for r in cands[:5]:
    print("PROTFORGE_COUPLING_SITE: %s%s chain=%s sasa=%.2f" % (r["residue"], r["resnum"], r["chain"], r["sasa"]))
PY

if [ -s "$OUT_HOST/adc_candidates.json" ]; then
  echo "PROTFORGE_OUTPUT_DIR: $OUT_HOST"
  echo "PROTFORGE_OUTPUT_JSON: $OUT_HOST/sasa_per_residue.json"
  echo "PROTFORGE_OUTPUT_CANDIDATES: $OUT_HOST/adc_candidates.json"
  protforge_ok
else
  protforge_fail "freesasa produced no output"
  exit 1
fi
