#!/usr/bin/env bash
# opendde runner: co-fold chains with OpenDDE (antibody-antigen checkpoint).
#
# Runs inside the AF3Native WSL distro. OpenDDE's input is a **top-level list**
# of jobs, each with `sequences` entries -- that is what the CLI expects, so
# the runner writes exactly that shape.
#
# Usage: protforge-opendde.sh <sequence> [msa_path] [checkpoint] [sample] \
#          [step] [cycle] [device] [use_msa] [use_template] [job_name]
#
#   sequence     comma-separated chains; each becomes one proteinChain.
#   msa_path     .a3m alignment for the FIRST chain (unpairedMsaPath).
#   checkpoint   file name under $OPENDDE_ROOT_DIR. 'opendde_abag.pt' is the
#                antibody-antigen tuned one; 'opendde.pt' is the general model.
#   sample       number of diffusion samples.
#   step         number of diffusion steps.
#   cycle        pairformer cycles.
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

SEQ="${1:?usage: protforge-opendde.sh <sequence> [msa_path] [checkpoint] [sample] [step] [cycle] [device] [use_msa] [use_template] [job_name]}"
MSA="${2:-}"
CKPT="${3:-opendde_abag.pt}"
SAMPLE="${4:-1}"
STEP="${5:-200}"
CYCLE="${6:-10}"
DEVICE="${7:-cuda}"
USE_MSA="${8:-true}"
USE_TEMPLATE="${9:-false}"
JOB="${10:-opendde}"

case "$SAMPLE$STEP$CYCLE" in
  ''|*[!0-9]*) protforge_fail "sample / step / cycle must be integers"; exit 1;;
esac
case "$USE_MSA" in true|false) ;; *) protforge_fail "use_msa must be true or false"; exit 1;; esac
case "$USE_TEMPLATE" in true|false) ;; *) protforge_fail "use_template must be true or false"; exit 1;; esac

IN_DIR="$PROTFORGE_DATA/inputs/${JOB}_opendde"
OUT_HOST="$PROTFORGE_DATA/outputs/${JOB}_opendde"
mkdir -p "$IN_DIR" "$OUT_HOST"

__seqs=""
__i=0
IFS=',' read -r -a __chains <<< "$SEQ"
for __s in "${__chains[@]}"; do
  __s="$(printf '%s' "$__s" | tr -d '[:space:]' | tr 'a-z' 'A-Z')"
  if [ -z "$__s" ]; then
    protforge_fail "empty chain in the sequence list"; exit 1
  fi
  case "$__s" in
    *[!ACDEFGHIKLMNPQRSTVWY]*)
      protforge_fail "chain ${__i} has non-standard amino acids: ${__s}"; exit 1;;
  esac
  __cid="$(printf '%s' "ABCDEFGHIJKLMNOPQRSTUVWXYZ" | cut -c$((__i + 1)))"
  if [ -z "$__seqs" ]; then
    __seqs="{\"proteinChain\": {\"sequence\": \"${__s}\", \"count\": 1"
    if [ -n "$MSA" ]; then
      __seqs="${__seqs}, \"unpairedMsaPath\": \"$(protforge_wsl_path "$MSA")\""
    fi
    __seqs="${__seqs}}}"
  else
    __seqs="${__seqs}, {\"proteinChain\": {\"sequence\": \"${__s}\", \"count\": 1}}"
  fi
  __i=$((__i + 1))
done

# **Top-level list** -- that is the shape OpenDDE's `pred` expects.
cat > "$IN_DIR/job.json" <<JSON
[{"sequences": [$__seqs]}]
JSON

JOB_WSL="$(protforge_wsl_path "$IN_DIR/job.json")"
OUT_WSL="$(protforge_wsl_path "$OUT_HOST")"

# Where the weights live. OPENDDE_ROOT_DIR must point at a directory that
# holds `common/components.cif` -- otherwise the code silently downloads it
# from huggingface.co, which is refused on this box, and the run dies looking
# like a model failure.
OPENDDE_ROOT_DIR="${OPENDDE_ROOT_DIR:-/mnt/e/oih/models/opendde}"
if [ ! -d "$OPENDDE_ROOT_DIR" ]; then
  protforge_fail "OPENDDE_ROOT_DIR not found: $OPENDDE_ROOT_DIR"
  exit 1
fi
if [ ! -f "$OPENDDE_ROOT_DIR/$CKPT" ]; then
  protforge_fail "checkpoint not found: $OPENDDE_ROOT_DIR/$CKPT"
  exit 1
fi

echo "[protforge] opendde job $JOB checkpoint=$CKPT -> $IN_DIR/job.json"

wsl.exe -d AF3Native -- mkdir -p "$OUT_WSL"
wsl.exe -d AF3Native -- env "OPENDDE_ROOT_DIR=$OPENDDE_ROOT_DIR" \
  bash -c "/opendde_venv/bin/opendde pred -i '${JOB_WSL}' -o '${OUT_WSL}' \
    --load_checkpoint_path '${OPENDDE_ROOT_DIR}/${CKPT}' \
    --use_msa ${USE_MSA} --use_template ${USE_TEMPLATE} \
    --sample ${SAMPLE} --step ${STEP} --cycle ${CYCLE} --device ${DEVICE}"

# OpenDDE writes a directory of per-seed results; take the whole tree back.
__found=0
while IFS= read -r __cif; do
  [ -n "$__cif" ] || continue
  __found=1
  echo "PROTFORGE_CIF: $__cif"
done < <(find "$OUT_HOST" -name '*.cif' 2>/dev/null | head -5)

if [ "$__found" = "1" ]; then
  echo "PROTFORGE_OUTPUT_DIR: $OUT_HOST"
  protforge_ok
else
  protforge_fail "opendde produced no cif"
  exit 1
fi
