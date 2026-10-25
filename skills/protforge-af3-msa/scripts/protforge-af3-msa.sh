#!/usr/bin/env bash
# af3-msa runner: search the AlphaFold 3 genetic database and write .a3m
# alignments (shared by OpenDDE and ESMFold2-full).
#
# Reads AF3's own /db **in place** -- no copy, no index. The tool dir holds
# oih_shared_msa.py, which imports AF3's own Jackhmmer wrapper so the search
# parameters match `run_alphafold.py --db_dir=/db` exactly.
#
# Usage: protforge-af3-msa.sh <fasta_path> [dbs] [n_cpu] [job_name]
#
#   fasta_path  query FASTA on the host.
#   dbs         comma list. 'mgnify' is opt-in (it lives on /mnt/e and reads
#               at ~168 MB/s, which dominates the run).
#   n_cpu       jackhmmer threads.
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

FASTA="${1:?usage: protforge-af3-msa.sh <fasta_path> [dbs] [n_cpu] [job_name]}"
DBS="${2:-uniref90,bfd}"
NCPU="${3:-12}"
JOB="${4:-af3msa}"

FASTA="${FASTA//\\//}"
case "$FASTA" in
  /*|[A-Za-z]:/*) ;;
  *) FASTA="$PROTFORGE_DATA/inputs/$FASTA" ;;
esac
if [ ! -f "$FASTA" ]; then
  protforge_fail "query fasta not found: $FASTA"; exit 1
fi
case "$NCPU" in
  ''|*[!0-9]*) protforge_fail "n_cpu must be an integer"; exit 1;;
esac

# Where oih_shared_msa.py lives. Deployment-local: override in
# scripts/local.env (AF3_MSA_TOOLS_DIR) -- the path is site-specific and must
# not be carried in the published source.
TOOLS_DIR="${AF3_MSA_TOOLS_DIR:-/mnt/e/oih/oih-upgrade/02-newtools}"
TOOLS_WSL="$(protforge_wsl_path "$TOOLS_DIR")"
if [ ! -f "$TOOLS_WSL/oih_shared_msa.py" ]; then
  protforge_fail "oih_shared_msa.py not found under $TOOLS_WSL (set AF3_MSA_TOOLS_DIR)"
  exit 1
fi

IN_DIR="$PROTFORGE_DATA/inputs/${JOB}_af3msa"
OUT_HOST="$PROTFORGE_DATA/outputs/${JOB}_af3msa"
mkdir -p "$IN_DIR" "$OUT_HOST"

# The query FASTA has to be readable from inside the distro.
cp "$FASTA" "$IN_DIR/query.fasta"
FASTA_WSL="$(protforge_wsl_path "$IN_DIR/query.fasta")"
OUT_WSL="$(protforge_wsl_path "$OUT_HOST")"

echo "[protforge] af3-msa job $JOB dbs=$DBS n_cpu=$NCPU -> $IN_DIR/query.fasta"

wsl.exe -d AF3Native -- mkdir -p "$OUT_WSL"
wsl.exe -d AF3Native -- bash -c "/alphafold3_venv/bin/python '${TOOLS_WSL}/oih_shared_msa.py' \
  --fasta '${FASTA_WSL}' --outdir '${OUT_WSL}' --dbs '${DBS}' --n-cpu ${NCPU}"

__n=$(find "$OUT_HOST" -name '*.a3m' 2>/dev/null | wc -l | tr -d ' ')
if [ "$__n" -gt 0 ]; then
  echo "PROTFORGE_OUTPUT_DIR: $OUT_HOST"
  echo "PROTFORGE_MSA_COUNT: $__n"
  find "$OUT_HOST" -name '*.a3m' | head -10 | while IFS= read -r __a; do
    echo "PROTFORGE_MSA: $__a"
  done
  protforge_ok
else
  protforge_fail "no a3m produced (the query may be novel -- that is a real answer, not a failure)"
  exit 1
fi
