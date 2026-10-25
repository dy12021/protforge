#!/usr/bin/env bash
# esmfold2 runner: fold a chain (or a complex) with ESMFold2.
#
# The model only runs inside the AF3Native WSL distro, so this runner:
#   1. writes the job JSON on the host (the contract lives here, not in WSL);
#   2. copies fold.py into the distro once -- inline quotes through wsl.exe
#      get mangled, so copy by path and invoke by path;
#   3. invokes it and copies the results back to the shared outputs dir.
#
# Usage: protforge-esmfold2.sh <sequence> [variant] [msa_path] \
#          [num_loops] [num_sampling_steps] [num_diffusion_samples] [seed] [job_name]
#
#   sequence   comma-separated chains ("SEQ_A,SEQ_B"); each chain becomes one
#              proteinChain. Standard 20 amino acids only.
#   variant    full (48 pair layers, accepts MSA) | fast (24 layers, single-seq).
#   msa_path   .a3m alignment for the FIRST chain. Honoured by 'full' only --
#              'fast' has no MSA encoder and drops it silently.
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

SEQ="${1:?usage: protforge-esmfold2.sh <sequence> [variant] [msa_path] [num_loops] [num_sampling_steps] [num_diffusion_samples] [seed] [job_name]}"
VARIANT="${2:-fast}"
MSA="${3:-}"
LOOPS="${4:-1}"
STEPS="${5:-14}"
SAMPLES="${6:-1}"
SEED="${7:-0}"
JOB="${8:-esmfold2}"

case "$VARIANT" in
  full|fast) ;;
  *) protforge_fail "variant must be full or fast, got: $VARIANT"; exit 1;;
esac
case "$LOOPS$STEPS$SAMPLES$SEED" in
  ''|*[!0-9]*) protforge_fail "loops / steps / samples / seed must be integers"; exit 1;;
esac

SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
IN_DIR="$PROTFORGE_DATA/inputs/${JOB}_esmfold2"
OUT_HOST="$PROTFORGE_DATA/outputs/${JOB}_esmfold2"
mkdir -p "$IN_DIR" "$OUT_HOST"

# --- build the job JSON ----------------------------------------------------
# The chain list is validated to standard amino acids before it goes into
# JSON, so no escaping is needed and the file stays readable for debugging.
__seqs=""
__msas=""
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
    __seqs="{\"id\": \"${__cid}\", \"sequence\": \"${__s}\"}"
    if [ -n "$MSA" ]; then __msas="\"${__cid}\": \"$(protforge_wsl_path "$MSA")\""; else __msas="\"${__cid}\": null"; fi
  else
    __seqs="${__seqs}, {\"id\": \"${__cid}\", \"sequence\": \"${__s}\"}"
    __msas="${__msas}, \"${__cid}\": null"
  fi
  __i=$((__i + 1))
done

cat > "$IN_DIR/job.json" <<JSON
{
  "name": "$JOB",
  "variant": "$VARIANT",
  "sequences": [$__seqs],
  "msa": {$__msas},
  "num_loops": $LOOPS,
  "num_sampling_steps": $STEPS,
  "num_diffusion_samples": $SAMPLES,
  "seed": $SEED
}
JSON

FOLD_WSL="$(protforge_wsl_path "$SELF_DIR/fold.py")"
JOB_WSL="$(protforge_wsl_path "$IN_DIR/job.json")"
OUT_WSL="$(protforge_wsl_path "$OUT_HOST")"

# --- local snapshot, so the hub must not be reachable ------------------------
# ESMFold2InputBuilder() downloads ccd.pkl (417 MB) from huggingface.co even
# when a local copy exists. That download stalls silently for ~28 minutes on a
# machine where the host is unreachable -- the run looks hung, not broken.
# ESMCFOLD_CCD_PATH wins over the cache dir, so point it at the local file
# and take the network out of the picture entirely.
__weights=""
for __root in ${ESMFOLD2_WEIGHTS:-} ${ESMFOLD2_MODELS_ROOTS:-} \
              /esmfold2/models /mnt/e/protforge/models; do
  [ -n "$__root" ] || continue
  if [ -f "$__root/$VARIANT/config.json" ] || [ -f "$__root/ESMFold2/config.json" ]; then
    __weights="$__root"; break
  fi
done
__ccd=""
for __root in ${ESMFOLD2_WEIGHTS:-} ${ESMFOLD2_MODELS_ROOTS:-} \
              /esmfold2/models /mnt/e/protforge/models; do
  [ -n "$__root" ] || continue
  if [ -f "$__root/ESMFold2/ccd.pkl" ]; then __ccd="$__root/ESMFold2/ccd.pkl"; break; fi
done

echo "[protforge] esmfold2 job $JOB variant=$VARIANT -> $IN_DIR/job.json"

# --- copy the runner into the distro, then run it by path -------------------
wsl.exe -d AF3Native -- mkdir -p /esmfold2/bin
wsl.exe -d AF3Native -- cp "$FOLD_WSL" /esmfold2/bin/fold.py
wsl.exe -d AF3Native -- mkdir -p /esmfold2/out
wsl.exe -d AF3Native -- mkdir -p "$OUT_WSL"

# ESMFOLD2_OFFLINE / ESMCFOLD_CCD_PATH are read by fold.py's own env lookups.
__env=()
[ -n "$__ccd" ] && __env+=("ESMCFOLD_CCD_PATH=$__ccd")
[ -n "$__weights" ] && __env+=("HF_HUB_OFFLINE=1")
__env+=("ESMFOLD2_WEIGHTS=$__weights")
__env+=("ESMFOLD2_MODELS_ROOTS=${ESMFOLD2_MODELS_ROOTS:-}")

# The interpreter path is absolute, so PATH does not have to be right.
wsl.exe -d AF3Native -- env "${__env[@]}" \
  bash -c "/esmfold2/venv/bin/python /esmfold2/bin/fold.py '${JOB_WSL}'"

# --- collect the results ----------------------------------------------------
wsl.exe -d AF3Native -- cp "/esmfold2/out/${JOB}.cif" "$OUT_WSL/${JOB}.cif" || true
wsl.exe -d AF3Native -- cp "/esmfold2/out/${JOB}_metrics.json" "$OUT_WSL/${JOB}_metrics.json" || true

if [ -s "$OUT_HOST/${JOB}.cif" ]; then
  echo "PROTFORGE_OUTPUT_DIR: $OUT_HOST"
  echo "PROTFORGE_CIF: $OUT_HOST/${JOB}.cif"
  [ -s "$OUT_HOST/${JOB}_metrics.json" ] && \
    echo "PROTFORGE_METRICS: $OUT_HOST/${JOB}_metrics.json"
  protforge_ok
else
  protforge_fail "esmfold2 produced no cif"
  exit 1
fi
