#!/usr/bin/env bash
# bindcraft runner: end-to-end binder design (PyRosetta-free stub mode).
# Design takes hours — this script validates inputs, writes target settings,
# and LAUNCHES the design detached in the protforge-bindcraft container.
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

# args: target_pdb target_chains hotspots job_name [num_final_designs]
TARGET_PDB="${1:?usage: bindcraft.sh <target_pdb> <target_chains> <hotspots> <job_name> [num_final_designs]}"
TARGET_CHAINS="${2:?usage: bindcraft.sh <target_pdb> <target_chains> <hotspots> <job_name> [num_final_designs]}"
HOTSPOTS="${3:?usage: bindcraft.sh <target_pdb> <target_chains> <hotspots> <job_name> [num_final_designs]}"
JOB="${4:?usage: bindcraft.sh <target_pdb> <target_chains> <hotspots> <job_name> [num_final_designs]}"
NUM_FINAL="${5:-5}"

TARGET_PDB="${TARGET_PDB//\\//}"
if [[ "$TARGET_PDB" =~ ^/([A-Za-z])/(.*)$ ]]; then
  TARGET_PDB="${BASH_REMATCH[1]^}:/${BASH_REMATCH[2]}"   # /e/protforge/... -> <data-root>/...
fi
if [[ ! "$TARGET_PDB" =~ ^[A-Za-z]:/ ]]; then
  TARGET_PDB="$PROTFORGE_DATA/inputs/$TARGET_PDB"
fi
[ -f "$TARGET_PDB" ] || { protforge_fail "input not found: $TARGET_PDB"; exit 1; }

OUT_HOST="$PROTFORGE_DATA/outputs/${JOB}_bindcraft"
mkdir -p "$OUT_HOST"

C_PDB="$(protforge_container_path "$TARGET_PDB")"
C_OUT="$(protforge_container_path "$OUT_HOST")"
case "$C_PDB" in
  "$PROTFORGE_MOUNT"/*) ;;
  *) protforge_fail "target PDB must live under $PROTFORGE_DATA (mounted as $PROTFORGE_MOUNT) so the container can read it"; exit 1 ;;
esac

# target settings json — bindcraft.py reads paths INSIDE the container,
# so all paths here must be container paths ($PROTFORGE_MOUNT/...).
SETTINGS_HOST="$PROTFORGE_DATA/inputs/settings_target/${JOB}.json"
mkdir -p "$PROTFORGE_DATA/inputs/settings_target"
C_SETTINGS="$(protforge_container_path "$SETTINGS_HOST")"

cat > "$SETTINGS_HOST" <<EOF
{
    "design_path": "$C_OUT/",
    "binder_name": "$JOB",
    "starting_pdb": "$C_PDB",
    "chains": "$TARGET_CHAINS",
    "target_hotspot_residues": "$HOTSPOTS",
    "lengths": [30, 80],
    "number_of_final_designs": $NUM_FINAL
}
EOF

protforge_ensure_container protforge-bindcraft || { protforge_fail "container protforge-bindcraft unavailable"; exit 1; }
name="$(protforge_container protforge-bindcraft)"

# launch detached; progress goes to run.log inside the output dir.
# Resolve the container name instead of hardcoding it: deployments created
# before the OIH -> ProtForge rename still run under `oih-bindcraft`, and a
# hardcoded `docker exec protforge-bindcraft` dies with "No such container".
# Under `set -e` that also skips the FAIL marker, breaking the status contract.
if ! docker exec -d "$name" sh -c \
  "cd /app/BindCraft && python3 -u bindcraft.py --settings '$C_SETTINGS' --filters ./settings_filters/default_filters.json --advanced ./settings_advanced/default_4stage_multimer.json > '$C_OUT/run.log' 2>&1"; then
  echo "PROTFORGE_OUTPUT_DIR: $OUT_HOST"
  protforge_fail "could not launch bindcraft inside container '$name'"
  exit 1
fi

# give it a few seconds and catch immediate startup crashes
sleep 20
if docker exec "$name" sh -c "grep -q 'Traceback (most recent call last)' '$C_OUT/run.log' 2>/dev/null"; then
  echo "PROTFORGE_OUTPUT_DIR: $OUT_HOST"
  echo "PROTFORGE_LOG: $OUT_HOST/run.log"
  protforge_fail "bindcraft crashed at startup (see run.log)"
  exit 1
fi

echo "PROTFORGE_OUTPUT_DIR: $OUT_HOST"
echo "PROTFORGE_LOG: $OUT_HOST/run.log"
echo "PROTFORGE_SETTINGS: $SETTINGS_HOST"
echo "PROTFORGE_NOTE: design launched detached (hours). Monitor via: tail $OUT_HOST/run.log"
protforge_ok
