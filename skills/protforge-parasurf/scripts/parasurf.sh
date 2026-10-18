#!/usr/bin/env bash
# parasurf runner: antibody-conditioned paratope-antigen interaction prediction.
#
# ParaSurf runs in the `parasurf` Docker image (see SKILL.md -- it is not a
# prebuilt protforge image; build it with Dockerfile.protforge). The repository
# and PYTHONPATH live inside the image at /workspace/ParaSurf, so this runner
# drives `docker run` rather than calling a host interpreter.
#
# Contract below was read from upstream blind_predict.py, not inferred from the
# README:
#   * --receptor is MISNAMED. Its help says "receptor (antibody or paratope) PDB
#     file" and the script runs antibody_input_recognition(), exiting 1 if the
#     structure is not an antibody. So the INPUT IS THE ANTIBODY, and ParaSurf
#     then predicts where on the antigen that antibody binds. This is what makes
#     it antibody-conditioned, unlike DiscoTope3.
#   * outputs are written NEXT TO THE INPUT PDB into a directory named after the
#     input stem: <stem>_pred.pdb, <stem>_pred_per_atom.pdb, centers.txt,
#     pocket<N>.pdb. A temporary *.surfpoints is dropped there too and removed at
#     the end. So the input is staged into the job directory before the run --
#     otherwise every invocation would litter $PROTFORGE_DATA/inputs.
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

# args: antibody_pdb [job_name] [weights.pth] [cpu|cuda]
PDB="${1:?usage: parasurf.sh <antibody_pdb> [job_name] [weights.pth] [cpu|cuda]}"
JOB="${2:-}"
WEIGHTS="${3:-${PROTFORGE_PARASURF_WEIGHTS:-}}"
DEVICE="${4:-${PROTFORGE_PARASURF_DEVICE:-cpu}}"
IMAGE="${PROTFORGE_PARASURF_IMAGE:-parasurf:latest}"

PDB="${PDB//\\//}"
if [[ "$PDB" =~ ^/([A-Za-z])/(.*)$ ]]; then
  PDB="${BASH_REMATCH[1]^}:/${BASH_REMATCH[2]}"
fi
if [[ ! "$PDB" =~ ^[A-Za-z]:/ ]]; then
  PDB="$PROTFORGE_DATA/inputs/$PDB"
fi
[ -f "$PDB" ] || { protforge_fail "input not found: $PDB"; exit 1; }

[ -n "$WEIGHTS" ] || { protforge_fail \
  "no weights file -- pass it, or set PROTORGE_PARASURF_WEIGHTS. Upstream ships a .pth per benchmark and its Docker/README.md fetches them with gdown inside the image."; exit 1; }
[ -f "$WEIGHTS" ] || { protforge_fail "weights file not found: $WEIGHTS"; exit 1; }
case "$DEVICE" in cuda|cpu) ;; *) protforge_fail "device must be cpu or cuda, got: $DEVICE"; exit 1 ;; esac

docker image inspect "$IMAGE" >/dev/null 2>&1 || { protforge_fail \
  "image '$IMAGE' not built. ParaSurf is not shipped prebuilt -- see SKILL.md for Dockerfile.protforge."; exit 1; }
command -v docker >/dev/null 2>&1 || { protforge_fail "docker not on PATH"; exit 1; }

STEM="$(basename "$PDB")"; STEM="${STEM%.*}"
JOB="${JOB:-$STEM}"
OUT_HOST="$PROTFORGE_DATA/outputs/${JOB}_parasurf"
rm -rf "$OUT_HOST"
STAGE="$OUT_HOST/_input"
mkdir -p "$STAGE"
cp "$PDB" "$STAGE/$STEM.pdb"

C_DATA="$(protforge_container_path "$PROTFORGE_DATA")"
C_STAGED="$(protforge_container_path "$STAGE/$STEM.pdb")"
C_WEIGHTS="$(protforge_container_path "$WEIGHTS")"

echo "PROTFORGE_PARASURF_IMAGE: $IMAGE"
echo "PROTFORGE_PARASURF_WEIGHTS: $WEIGHTS"
echo "PROTFORGE_PARASURF_DEVICE: $DEVICE"
echo "PROTFORGE_PARASURF_NOTE: input must be an ANTIBODY; the --receptor flag is misnamed upstream"

# GPU is only attached when asked for. The bundled image ships a CPU torch by
# default, so 'cuda' will fail loudly rather than silently fall back.
GPU_ARG=()
if [ "$DEVICE" = "cuda" ] && command -v nvidia-smi >/dev/null 2>&1; then
  GPU_ARG=(--gpus all)
fi

set +e
docker run --rm "${GPU_ARG[@]}" \
  -v "$C_DATA":/data/protforge \
  -v "$C_WEIGHTS":/data/weights/model.pth:ro \
  -w /workspace/ParaSurf \
  -e PYTHONPATH=/workspace/ParaSurf \
  "$IMAGE" \
  python -u blind_predict.py \
    --receptor "$C_STAGED" \
    --model_weights /data/weights/model.pth \
    --device "$DEVICE" \
  > "$OUT_HOST/run.log" 2>&1
rc=$?
set -e

# Upstream prints a traceback and calls exit(1) when the input is not an
# antibody; check the log as well, so a zero rc with a failed run is still caught.
if [ "$rc" -ne 0 ] || grep -q "Traceback (most recent call last)\|Validation Failed" "$OUT_HOST/run.log"; then
  echo "PROTFORGE_OUTPUT_DIR: $OUT_HOST"
  tail -n 30 "$OUT_HOST/run.log" >&2
  protforge_fail "parasurf errored (rc=$rc, see run.log)"
  exit 1
fi

# Upstream writes into <staged_stem>/; lift those next to the log.
if [ -d "$STAGE/$STEM" ]; then
  cp -R "$STAGE/$STEM/." "$OUT_HOST/" 2>/dev/null || true
fi
rm -rf "$STAGE"

echo "PROTFORGE_OUTPUT_DIR: $OUT_HOST"
echo "PROTFORGE_PARASURF_FILES:"
find "$OUT_HOST" -type f | sort || true

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
