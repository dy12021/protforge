#!/usr/bin/env bash
# parasurf runner: antibody-conditioned paratope-antigen interaction prediction.
#
# NOT preinstalled by this plugin -- ParaSurf needs a conda env, OpenBabel, a
# locally built `dms` library and weights that upstream hosts on Google Drive
# (their Docker/README.md uses gdown to fetch them). This script fails loudly
# when any of that is missing rather than producing an empty result.
#
# Contract below was read from upstream blind_predict.py, not inferred from the
# README:
#   * --receptor is MISNAMED. Its help says "receptor (antibody or paratope) PDB
#     file" and the script runs antibody_input_recognition() on it, exiting 1 if
#     the structure is not an antibody. So the INPUT IS THE ANTIBODY. ParaSurf
#     then predicts where on the antigen that antibody binds. This is what makes
#     it antibody-conditioned, unlike DiscoTope3.
#   * outputs are written NEXT TO THE INPUT PDB, into a directory named after
#     the input stem: <stem>_pred.pdb, <stem>_pred_per_atom.pdb, centers.txt,
#     pocket<N>.pdb. It also drops and removes *.surfpoints in the same folder.
#     Therefore this runner stages a COPY of the input into the job dir instead
#     of running on the caller's file, or every run would litter the input dir.
set -euo pipefail
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

# args: pdb_path [job_name] [weights_file] [device]
PDB="${1:?usage: parasurf.sh <antibody_pdb> [job_name] [weights.pth] [cuda|cpu]}"
JOB="${2:-}"
WEIGHTS="${3:-${PROTFORGE_PARASURF_WEIGHTS:-}}"
DEVICE="${4:-${PROTFORGE_PARASURF_DEVICE:-cuda}}"
HOME_DIR="${PROTFORGE_PARASURF_HOME:-}"

PDB="${PDB//\\//}"
if [[ "$PDB" =~ ^/([A-Za-z])/(.*)$ ]]; then
  PDB="${BASH_REMATCH[1]^}:/${BASH_REMATCH[2]}"
fi
if [[ ! "$PDB" =~ ^[A-Za-z]:/ ]]; then
  PDB="$PROTFORGE_DATA/inputs/$PDB"
fi
[ -f "$PDB" ] || { protforge_fail "input not found: $PDB"; exit 1; }

[ -n "$HOME_DIR" ] || { protforge_fail \
  "PROTFORGE_PARASURF_HOME is unset -- point it at the ParaSurf checkout"; exit 1; }
[ -f "$HOME_DIR/blind_predict.py" ] || { protforge_fail \
  "no blind_predict.py under $PROTFORGE_PARASURF_HOME"; exit 1; }
[ -n "$WEIGHTS" ] || { protforge_fail \
  "no weights file -- pass it, or set PROTORGE_PARASURF_WEIGHTS (upstream ships a .pth per benchmark; their Docker/README.md fetches them with gdown)"; exit 1; }
[ -f "$WEIGHTS" ] || { protforge_fail "weights file not found: $WEIGHTS"; exit 1; }
case "$DEVICE" in cuda|cpu) ;; *) protforge_fail "device must be cuda or cpu, got: $DEVICE"; exit 1 ;; esac

PY="${PROTFORGE_PARASURF_PYTHON:-python3}"
command -v "$PY" >/dev/null 2>&1 || { protforge_fail \
  "no '$PY' on PATH -- set PROTORGE_PARASURF_PYTHON to the ParaSurf conda env"; exit 1; }

STEM="$(basename "$PDB")"; STEM="${STEM%.*}"
JOB="${JOB:-$STEM}"
OUT_HOST="$PROTFORGE_DATA/outputs/${JOB}_parasurf"
rm -rf "$OUT_HOST"
STAGE="$OUT_HOST/_input"
mkdir -p "$STAGE"
# blind_predict.py writes its outputs and a temporary *.surfpoints into
# os.path.dirname(--receptor), so the copy has to be the thing we point at.
cp "$PDB" "$STAGE/$STEM.pdb"
STAGED="$STAGE/$STEM.pdb"

cd "$HOME_DIR"
export PYTHONPATH="$HOME_DIR${PYTHONPATH:+:$PYTHONPATH}"

echo "PROTFORGE_PARASURF_HOME: $HOME_DIR"
echo "PROTFORGE_PARASURF_WEIGHTS: $WEIGHTS"
echo "PROTFORGE_PARASURF_DEVICE: $DEVICE"
echo "PROTFORGE_PARASURF_NOTE: input must be an ANTIBODY (the --receptor flag is misnamed); upstream exits 1 on anything else"

set +e
"$PY" -u blind_predict.py --receptor "$STAGED" \
      --model_weights "$WEIGHTS" --device "$DEVICE" \
      > "$OUT_HOST/run.log" 2>&1
rc=$?
set -e

# Upstream prints a traceback and calls exit(1) when the input is not an
# antibody; check the log as well as the code, so a non-1 rc is still surfaced.
if [ "$rc" -ne 0 ] || grep -q "Traceback (most recent call last)\|Validation Failed" "$OUT_HOST/run.log"; then
  echo "PROTFORGE_OUTPUT_DIR: $OUT_HOST"
  tail -n 30 "$OUT_HOST/run.log" >&2
  protforge_fail "parasurf errored (rc=$rc, see run.log)"
  exit 1
fi

# Upstream writes into <staged_stem>/ ; lift those next to the log.
if [ -d "$STAGE/$STEM" ]; then
  cp -R "$STAGE/$STEM/." "$OUT_HOST/" 2>/dev/null || true
fi
rm -rf "$STAGE"

echo "PROTFORGE_OUTPUT_DIR: $OUT_HOST"
echo "PROTFORGE_PARASURF_FILES:"
find "$OUT_HOST" -type f | sort || true

# Report what the run actually produced rather than a count invented from the
# log. Upstream's stable outputs are *_pred.pdb (per residue), *_pred_per_atom.pdb,
# centers.txt and pocket<N>.pdb.
N_RES="$(find "$OUT_HOST" -name '*_pred.pdb' | wc -l | tr -d ' ')"
N_POCKET="$(find "$OUT_HOST" -name 'pocket*.pdb' | wc -l | tr -d ' ')"
echo "PROTFORGE_PARASURF_RESIDUE_FILES: $N_RES"
echo "PROTFORGE_PARASURF_POCKETS: $N_POCKET"
if [ "$N_RES" -eq 0 ]; then
  protforge_fail "parasurf finished but wrote no *_pred.pdb -- inspect run.log before trusting this run"
  exit 1
fi
# ParaSurf reports where this antibody binds. It says nothing about affinity.
echo "PROTFORGE_PARASURF_NOTE: binding-site prediction only, not an affinity score"
protforge_ok
