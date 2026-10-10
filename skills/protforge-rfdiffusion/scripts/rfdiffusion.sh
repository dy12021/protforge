#!/usr/bin/env bash
# RFdiffusion runner: de novo backbone generation (binder backbones, motif
# scaffolding, symmetric assemblies, partial diffusion).
#
# Weights live in a Docker named volume mounted read-only into the container;
# the legacy host path under $PROTFORGE_MODELS is used as a fallback.
set -uo pipefail
source "$(dirname "$0")/../../../scripts/_common.sh"

target="${1:?usage: rfdiffusion.sh <target.pdb> <job> <contig> <hotspots> [n_designs] [gpu]}"
job="${2:?missing job name}"
contig="${3:?missing contig}"
hotspots="${4:-none}"
n_designs="${5:-10}"
gpu_slot="${6:-0}"

target="${target//\\//}"
if [[ ! "$target" =~ ^[A-Za-z]:/ && "$target" != /* ]]; then
  target="$PROTFORGE_DATA/inputs/$target"
fi
[ -f "$target" ] || { protforge_fail "input not found: $target"; exit 1; }

ctarget="$(protforge_container_path "$target")"

protforge_ensure_container protforge-rfdiffusion || {
  protforge_fail "cannot start the protforge-rfdiffusion container"
  exit 1
}
name="$(protforge_container protforge-rfdiffusion)"

# pick the Nth freest GPU (0-based)
gpuidx=$(nvidia-smi --query-gpu=index,memory.used --format=csv,noheader,nounits 2>/dev/null \
         | sort -t, -k2 -n | cut -d, -f1 | tr -d ' ' | sed -n "$((gpu_slot + 1))p")
[ -z "$gpuidx" ] && gpuidx=0

# Weights. Probe the current volume name, then the pre-rename one, and only
# accept a volume that actually has the checkpoint mounted where we expect it.
models="$PROTFORGE_MOUNT/models/rfdiffusion"
for vol in vol_protforge_models vol_oih_models; do
  docker volume inspect "$vol" >/dev/null 2>&1 || continue
  if docker exec "$name" test -f "$models/Complex_base_ckpt.pt" 2>/dev/null; then
    break
  fi
  echo "[protforge] $vol exists but $models/Complex_base_ckpt.pt is missing;" \
       "falling back to the host models path" >&2
done

outdir="$PROTFORGE_DATA/outputs/${job}_rfdiffusion"
mkdir -p "$outdir"
coutdir="$(protforge_container_path "$outdir")"

echo "[protforge] rfdiffusion: target=$ctarget contig='$contig' hotspots=$hotspots n=$n_designs gpu=$gpuidx"

docker exec -e CUDA_VISIBLE_DEVICES="$gpuidx" "$name" \
  python /app/RFdiffusion/scripts/run_inference.py \
    inference.output_prefix="$coutdir/rfd" \
    inference.input_pdb="$ctarget" \
    "contigmap.contigs=[$contig]" \
    "ppi.hotspot_res=[$hotspots]" \
    inference.num_designs="$n_designs" \
    inference.model_directory_path="$models" \
    denoiser.noise_scale_ca=0 denoiser.noise_scale_frame=0 \
    2>&1 | grep -vE "^\[20|UserWarning|sh = _spherical|floor|to debug" | tail -30

# count what actually landed
n=$(find "$outdir" -maxdepth 1 -name 'rfd_*.pdb' 2>/dev/null | wc -l | tr -d ' ')
echo "PROTFORGE_OUTPUT_DIR: $outdir"
echo "PROTFORGE_BACKBONES: $n"
if [ "$n" -gt 0 ]; then
  protforge_ok
  echo "NEXT: ProteinMPNN sequence design, then AF3 interface validation"
else
  protforge_fail "no backbones produced"
fi