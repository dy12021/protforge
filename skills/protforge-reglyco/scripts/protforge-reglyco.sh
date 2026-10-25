#!/usr/bin/env bash
# reglyco runner: glycosylation-aware validation and filtering (ReGlyco).
#
# Runs on the HOST: reglyco is a native Rust CLI (cargo install reglyco), not
# a container. The glycan ensembles come from glycoshape.org.
#
# Usage: protforge-reglyco.sh <pdb_path> [subcommand] [glycan] [attach] \
#          [hotspots] [job_name]
#
#   pdb_path    the structure to work on. For the binder-clash test this is
#               the FULL complex (target chain + designed binder).
#   subcommand  scan | ensemble | build | relax.
#   glycan      GlyTouCan id, e.g. G14843DJ.
#   attach      site spec for `build`, e.g. 'A:64=G98687PM' (semicolon
#               separated for several sites). Numbering is the INPUT PDB's
#               numbering, not UniProt.
#   hotspots    true -> --calculate-hotspots (ensemble only; `scan` does not
#               have that flag in 0.2.3).
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

PDB="${1:?usage: protforge-reglyco.sh <pdb_path> [subcommand] [glycan] [attach] [hotspots] [job_name]}"
SUBCMD="${2:-scan}"
GLYCAN="${3:-G14843DJ}"
ATTACH="${4:-}"
HOTSPOTS="${5:-false}"
JOB="${6:-reglyco}"

case "$SUBCMD" in
  scan|ensemble|build|relax) ;;
  *) protforge_fail "subcommand must be scan|ensemble|build|relax, got: $SUBCMD"; exit 1;;
esac
case "$HOTSPOTS" in true|false) ;; *) protforge_fail "hotspots must be true or false"; exit 1;; esac

PDB="${PDB//\\//}"
case "$PDB" in
  /*|[A-Za-z]:/*) ;;
  *) PDB="$PROTFORGE_DATA/inputs/$PDB" ;;
esac
if [ ! -f "$PDB" ]; then
  protforge_fail "input structure not found: $PDB"; exit 1
fi

# reglyco is a native CLI. cargo puts it in ~/.cargo/bin, which is not always
# on the PATH of a non-interactive shell.
REG="${REGLYCO_BIN:-}"
if [ -z "$REG" ]; then
  if command -v reglyco >/dev/null 2>&1; then
    REG="$(command -v reglyco)"
  elif [ -x "$HOME/.cargo/bin/reglyco" ]; then
    REG="$HOME/.cargo/bin/reglyco"
  elif [ -x "$HOME/.cargo/bin/reglyco.exe" ]; then
    REG="$HOME/.cargo/bin/reglyco.exe"
  else
    protforge_fail "reglyco not found (cargo install reglyco --locked --version 0.2.3)"
    exit 1
  fi
fi

OUT_HOST="$PROTFORGE_DATA/outputs/${JOB}_reglyco"
mkdir -p "$OUT_HOST"

# reglyco.exe is a native Windows program: a Git Bash POSIX path would be
# resolved against the drive it happens to be on ("/e/x.pdb" -> "C:\e\x.pdb").
# **Two forms, on purpose**: the shell's own tools (find, mkdir) want the
# path it understands, the native binary wants the Windows one.
PDB_WIN="$(protforge_win_path "$PDB")"
OUT_WIN="$(protforge_win_path "$OUT_HOST")"

echo "[protforge] reglyco $SUBCMD $PDB glycan=$GLYCAN -> $OUT_HOST"

__args=("$SUBCMD" --protein "$PDB_WIN" --glycan "$GLYCAN" --output "$OUT_WIN")
case "$SUBCMD" in
  build)
    if [ -z "$ATTACH" ]; then
      protforge_fail "build needs attach sites, e.g. 'A:64=G98687PM'"; exit 1
    fi
    IFS=';' read -r -a __sites <<< "$ATTACH"
    for __site in "${__sites[@]}"; do
      __site="$(printf '%s' "$__site" | tr -d '[:space:]')"
      [ -n "$__site" ] || continue
      __args+=(--attach "$__site")
    done
    __args+=(--rotamers --report)
    ;;
  ensemble)
    if [ "$HOTSPOTS" = "true" ]; then __args+=(--calculate-hotspots); fi
    ;;
esac

"$REG" "${__args[@]}"

if [ -n "$(find "$OUT_HOST" -type f 2>/dev/null | head -1)" ]; then
  echo "PROTFORGE_OUTPUT_DIR: $OUT_HOST"
  find "$OUT_HOST" -maxdepth 2 -type f | head -10 | while IFS= read -r __f; do
    echo "PROTFORGE_FILE: $__f"
  done
  protforge_ok
else
  protforge_fail "reglyco produced no output"
  exit 1
fi
