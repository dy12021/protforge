#!/usr/bin/env bash
# parasurf runner: paratope-antigen interaction interface prediction.
#
# NOT preinstalled. ParaSurf needs a python 3.10 conda env, OpenBabel, a locally
# built `dms` library and manually downloaded weights (they are on Google Drive,
# not on pip or HuggingFace). This script fails loudly when any of that is
# missing rather than producing an empty result that reads as "0 interfaces".
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

# args: pdb_path [job_name] [weights_dir]
PDB="${1:?usage: parasurf.sh <pdb_path> [job_name] [weights_dir]}"
JOB="${2:-}"
WEIGHTS="${3:-$PROTFORGE_MODELS/parasurf}"
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
[ -d "$HOME_DIR" ] || { protforge_fail \
  "PROTFORGE_PARASURF_HOME does not exist: $HOME_DIR"; exit 1; }
[ -f "$HOME_DIR/blind_predict.py" ] || { protforge_fail \
  "no blind_predict.py under $HOME_DIR"; exit 1; }
[ -d "$WEIGHTS" ] || { protforge_fail \
  "weights dir not found: $WEIGHTS (ParaSurf weights are downloaded manually from Google Drive)"; exit 1; }

# ParaSurf is imported as a package from the checkout root, so PYTHONPATH is a
# hard requirement -- without it the import fails inside the model, not here.
PY="${PROTFORGE_PARASURF_PYTHON:-python3}"
command -v "$PY" >/dev/null 2>&1 || { protforge_fail \
  "no '$PY' on PATH -- set PROTORGE_PARASURF_PYTHON to the ParaSurf conda env"; exit 1; }

STEM="$(basename "$PDB")"; STEM="${STEM%.*}"
JOB="${JOB:-$STEM}"
OUT_HOST="$PROTFORGE_DATA/outputs/${JOB}_parasurf"
mkdir -p "$OUT_HOST"

# Surface it once: the README prose ("an antibody file") and the flag name
# (--receptor) disagree upstream, so the operator must confirm the contract on
# their own install rather than trusting this script.
echo "PROTFORGE_PARASURF_HOME: $HOME_DIR"
echo "PROTFORGE_PARASURF_WEIGHTS: $WEIGHTS"
echo "PROTFORGE_NOTE: confirm the input contract with 'python blind_predict.py --help' before trusting this run"

cd "$HOME_DIR"
export PYTHONPATH="$HOME_DIR${PYTHONPATH:+:$PYTHONPATH}"

set +e
"$PY" -u blind_predict.py --receptor "$PDB" --model_weights "$WEIGHTS" \
      > "$OUT_HOST/run.log" 2>&1
rc=$?
set -e

# Upstream prints tracebacks but does not always return non-zero, so the exit
# code alone is not a pass/fail signal.
if [ "$rc" -ne 0 ] || grep -q "Traceback (most recent call last)" "$OUT_HOST/run.log"; then
  echo "PROTFORGE_OUTPUT_DIR: $OUT_HOST"
  tail -n 25 "$OUT_HOST/run.log" >&2
  protforge_fail "parasurf errored (rc=$rc, see run.log)"
  exit 1
fi

echo "PROTFORGE_OUTPUT_DIR: $OUT_HOST"
echo "PROTFORGE_PARASURF_FILES:"
find "$OUT_HOST" -type f | sort || true

# Do not emit an interface count by parsing run.log: upstream does not promise a
# stable output schema, and a number invented from log text is worse than none.
# List the files and let the operator read them.
if [ -z "$(find "$OUT_HOST" -type f ! -name run.log -print -quit)" ]; then
  protforge_fail "parasurf produced no output files besides run.log"
  exit 1
fi
protforge_ok
