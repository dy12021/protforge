#!/usr/bin/env bash
# igfold runner: antibody / nanobody structure prediction.
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

# args: job_name heavy_seq [light_seq] [do_refine]
JOB="${1:?usage: igfold.sh <job_name> <heavy_seq> [light_seq] [do_refine]}"
HEAVY="${2:?usage: igfold.sh <job_name> <heavy_seq> [light_seq] [do_refine]}"
LIGHT="${3:-}"
DO_REFINE="${4:-false}"

OUT_HOST="$PROTFORGE_DATA/outputs/${JOB}_igfold"
mkdir -p "$OUT_HOST"
C_OUT="$(protforge_container_path "$OUT_HOST")"
PY_HOST="$PROTFORGE_DATA/tmp/${JOB}_igfold.py"
mkdir -p "$PROTFORGE_DATA/tmp"
C_PY="$(protforge_container_path "$PY_HOST")"

# build the sequences dict
if [ -n "$LIGHT" ]; then
  SEQDICT="{'H': '''$HEAVY''', 'L': '''$LIGHT'''}"
else
  SEQDICT="{'H': '''$HEAVY'''}"
fi

# python boolean literal
PY_REFINE="False"
if [ "$DO_REFINE" = "true" ]; then
  PY_REFINE="True"
fi

cat > "$PY_HOST" <<EOF
import json
import torch
from igfold import IgFoldRunner

out_dir = "$C_OUT"
pred_stem = out_dir + "/pred.pdb"
runner = IgFoldRunner()
pred = runner.fold(pred_stem, sequences=$SEQDICT, do_refine=$PY_REFINE, do_renum=False)

prmsd = pred.prmsd.float().cpu()
mean_prmsd = prmsd.mean().item()
res_plddt = (100.0 - prmsd.mean(dim=-1).clamp(0, 5) * 20.0).clamp(0, 100)
mean_plddt = res_plddt.mean().item()
n_res = int(prmsd.shape[1])

result = {
    "job": "$JOB",
    "mean_prmsd": round(mean_prmsd, 4),
    "mean_plddt": round(mean_plddt, 2),
    "num_residues": n_res,
    "do_refine": $PY_REFINE,
    "pdb": pred_stem,
}
with open(out_dir + "/result.json", "w") as f:
    json.dump(result, f, indent=2)
print(json.dumps(result))
EOF

protforge_exec protforge-igfold python3 "$C_PY" || { protforge_fail "igfold run failed"; exit 1; }

if [ -f "$OUT_HOST/pred.pdb" ] && [ -f "$OUT_HOST/result.json" ]; then
  echo "PROTFORGE_OUTPUT_DIR: $OUT_HOST"
  echo "PROTFORGE_PDB: $OUT_HOST/pred.pdb"
  grep -h "mean_plddt\|num_residues" "$OUT_HOST/result.json"
  protforge_ok
else
  protforge_fail "igfold produced no prediction"
  exit 1
fi
