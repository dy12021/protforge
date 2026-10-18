#!/usr/bin/env bash
# polyxpert runner: sequence-only antibody polyreactivity scoring.
#
# Contract below was read from upstream PolyXpert.py, not inferred from the
# README: pd.read_csv(sep='\t') over columns Name/VH/VL, the model loaded from
# the relative path './PolyXpert' (so CWD must be the repo root), and results
# written with to_csv into './results/' -- pandas does NOT create that directory,
# so it has to exist before the run or the job dies at the very last step.
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

# args: input_tsv [job_name] [polyxpert_home]
IN="${1:?usage: polyxpert.sh <input_tsv> [job_name] [polyxpert_home]}"
JOB="${2:-}"
PF_HOME="${3:-${PROTFORGE_POLYXPERT_HOME:-$PROTFORGE_MODELS/PolyXpert}}"

IN="${IN//\\//}"
if [[ "$IN" =~ ^/([A-Za-z])/(.*)$ ]]; then
  IN="${BASH_REMATCH[1]^}:/${BASH_REMATCH[2]}"
fi
[[ "$IN" =~ ^[A-Za-z]:/ ]] || IN="$PROTFORGE_DATA/inputs/$IN"
[ -f "$IN" ] || { protforge_fail "input not found: $IN"; exit 1; }

[ -f "$PF_HOME/PolyXpert.py" ] || { protforge_fail \
  "no PolyXpert.py under $PF_HOME (set PROTORGE_POLYXPERT_HOME or pass it)"; exit 1; }
[ -d "$PF_HOME/PolyXpert" ] || { protforge_fail \
  "missing $PF_HOME/PolyXpert -- the unzipped weights must sit next to PolyXpert.py"; exit 1; }

# --- validate the input BEFORE spending model load time -----------------------
# Upstream silently rewrites O/B/U/Z to X and keeps going, so a design with a
# non-standard residue scores normally and nobody notices. Reject it here.
awk -F'\t' '
  NR==1 {
    for (i=1;i<=NF;i++) { gsub(/\r/,"",$i); h[$i]=i }
    if (!( "Name" in h) || !("VH" in h) || !("VL" in h)) {
      print "missing column(s); header was: " $0 > "/dev/stderr"; exit 3
    }
    ni=h["Name"]; hi=h["VH"]; li=h["VL"]; next
  }
  NF<3 { print "row " NR " has " NF " fields, expected 3" > "/dev/stderr"; exit 3 }
  {
    n=$ni; vh=$hi; vl=$li
    gsub(/\r/,"",n); gsub(/\r/,"",vh); gsub(/\r/,"",vl)
    if (n in seen) { print "duplicate Name: " n > "/dev/stderr"; exit 4 }
    seen[n]=1
    if (vh == "" || vl == "") { print "empty VH/VL for " n > "/dev/stderr"; exit 5 }
    if (vh !~ /^[ACDEFGHIKLMNPQRSTVWY]+$/ || vl !~ /^[ACDEFGHIKLMNPQRSTVWY]+$/) {
      print "non-standard residue in " n " (O/B/U/Z are not standard residues)" > "/dev/stderr"
      exit 6
    }
  }
' "$IN" || { rc=$?; protforge_fail "input TSV rejected (awk rc=$rc; see message above)"; exit 1; }

STEM="$(basename "$IN")"; STEM="${STEM%.*}"
JOB="${JOB:-$STEM}"
OUT_HOST="$PROTFORGE_DATA/outputs/${JOB}_polyxpert"
mkdir -p "$OUT_HOST"

mkdir -p "$PF_HOME/results"

# CWD must be the repo root: the model is loaded from the relative './PolyXpert'.
cd "$PF_HOME"
PY="${PROTFORGE_POLYXPERT_PYTHON:-python}"
command -v "$PY" >/dev/null 2>&1 || { protforge_fail \
  "no '$PY' on PATH -- set PROTORGE_POLYXPERT_PYTHON to the polyxpert conda env"; exit 1; }

set +e
"$PY" PolyXpert.py "$IN" > "$OUT_HOST/run.log" 2>&1
rc=$?
set -e

if [ "$rc" -ne 0 ] || grep -q "Traceback (most recent call last)" "$OUT_HOST/run.log"; then
  echo "PROTFORGE_OUTPUT_DIR: $OUT_HOST"
  tail -n 25 "$OUT_HOST/run.log" >&2
  protforge_fail "polyxpert errored (rc=$rc, see run.log)"
  exit 1
fi

RES="$(ls -1t results/pred_results_*.txt 2>/dev/null | head -1 || true)"
if [ -z "$RES" ]; then
  echo "PROTFORGE_OUTPUT_DIR: $OUT_HOST"
  tail -n 25 "$OUT_HOST/run.log" >&2
  protforge_fail "polyxpert produced no results/pred_results_*.txt"
  exit 1
fi

cp "$RES" "$OUT_HOST/pred_results.txt"

echo "PROTFORGE_OUTPUT_DIR: $OUT_HOST"
echo "PROTFORGE_POLYXPERT_FILES:"
find "$OUT_HOST" -type f | sort || true
echo "PROTFORGE_POLYXPERT_NOTE: proba_1 is P(polyreactive), not an affinity score; no upstream threshold exists -- do not invent one"

# per-candidate readout; tab-separated, index column is Name
awk -F'\t' 'NR==1{for(i=1;i<=NF;i++){gsub(/\r/,"",$i);h[$i]=i}; next}
     {printf "%-28s proba_1=%-8s pred_label=%s\n", $1, $(h["proba_1"]), $(h["pred_label"])}' \
    "$OUT_HOST/pred_results.txt"

protforge_ok
