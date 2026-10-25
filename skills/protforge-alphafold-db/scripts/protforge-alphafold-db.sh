#!/usr/bin/env bash
# alphafold-db runner: download a pre-computed AlphaFold DB model.
#
# Runs on the HOST python (afdb.py is stdlib-only: query + summary + download).
#
# Usage: protforge-alphafold-db.sh <accession> [files] [query_only] [job_name]
#
#   accession   UniProt accession (e.g. P69905) or AF DB entry id
#               (AF-P69905-F1).
#   files       comma list from cif,pdb,pae,plddt,msa,bcif,pae-img,am
#               (default cif,pdb,pae,plddt). 'msa' (.a3m) can be tens of MB.
#   query_only  true -> print the summary without downloading.
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

ACC="${1:?usage: protforge-alphafold-db.sh <accession> [files] [query_only] [job_name]}"
FILES="${2:-cif,pdb,pae,plddt}"
QUERY_ONLY="${3:-false}"
JOB="${4:-afdb}"

case "$QUERY_ONLY" in true|false) ;; *) protforge_fail "query_only must be true or false"; exit 1;; esac

SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
AFDB="$SELF_DIR/afdb.py"
if [ ! -f "$AFDB" ]; then
  protforge_fail "afdb.py not found next to this runner"; exit 1
fi
# The host python is a native Windows program: it cannot read a Git Bash
# POSIX path ("/e/..." resolves to "C:\e\..." there).
AFDB="$(protforge_win_path "$AFDB")"

# Host python. afdb.py is stdlib-only, so any python 3.8+ works; prefer the
# deployment venv, fall back to whatever is on PATH.
PY="${PROTFORGE_PYTHON:-}"
if [ -z "$PY" ] || [ ! -x "$PY" ]; then
  if command -v python >/dev/null 2>&1; then
    PY="$(command -v python)"
  elif command -v python3 >/dev/null 2>&1; then
    PY="$(command -v python3)"
  else
    protforge_fail "no host python found"; exit 1
  fi
fi

OUT_HOST="$PROTFORGE_DATA/outputs/${JOB}_afdb"
mkdir -p "$OUT_HOST"

echo "[protforge] alphafold-db $ACC files=$FILES query_only=$QUERY_ONLY -> $OUT_HOST"

__args=("$ACC" --out "$OUT_HOST" --files "$FILES")
[ "$QUERY_ONLY" = "true" ] && __args+=(--query-only)

set +e
"$PY" "$AFDB" "${__args[@]}"
__rc=$?
set -e

# afdb.py prints PROTFORGE_STATUS: OK|FAIL itself. A non-zero exit means the
# lookup failed (bad accession, no entry, network error) -- report it as a
# failure rather than letting the runner claim success.
if [ "$__rc" -ne 0 ]; then
  protforge_fail "afdb.py exited $__rc"
  exit "$__rc"
fi

if [ "$QUERY_ONLY" = "true" ]; then
  echo "PROTFORGE_OUTPUT_DIR: $OUT_HOST"
  protforge_ok
  exit 0
fi

__cif="$(find "$OUT_HOST" -name '*.cif' 2>/dev/null | head -1)"
if [ -n "$__cif" ]; then
  echo "PROTFORGE_OUTPUT_DIR: $OUT_HOST"
  echo "PROTFORGE_CIF: $__cif"
  find "$OUT_HOST" -maxdepth 1 -type f | head -10 | while IFS= read -r __f; do
    echo "PROTFORGE_FILE: $__f"
  done
  protforge_ok
else
  protforge_fail "no model downloaded (no public AlphaFold DB entry for $ACC?)"
  exit 1
fi
