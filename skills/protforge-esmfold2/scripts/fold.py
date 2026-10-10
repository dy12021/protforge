"""ESMFold2 job runner. Reads a job JSON, folds, writes mmCIF + metrics.

Job JSON:
{
  "name": "job1",
  "variant": "full" | "fast",
  "sequences": [{"id": "A", "sequence": "..."}, {"id": "B", "sequence": "..."}],
  "msa": {"A": "/esmfold2/msa/xxx.a3m", "B": null},   # optional, full only
  "num_loops": 10, "num_sampling_steps": 68, "num_diffusion_samples": 5,
  "seed": 0
}
"""
import json
import os
import sys
import time

import torch

# ---- must precede any folding: cusolver SVD poisoning --------------------
_orig_svd = torch.linalg.svd


def _safe_svd(A, full_matrices=True, driver=None):
    if A.is_cuda and A.shape[-1] <= 4 and A.shape[-2] <= 4:
        Acpu = A.detach().float().cpu()
        if not torch.isfinite(Acpu).all():
            Acpu = torch.nan_to_num(Acpu, nan=0.0, posinf=1e6, neginf=-1e6)
        out = _orig_svd(Acpu, full_matrices=full_matrices)
        return type(out)(tuple(t.to(A.device, A.dtype) for t in out))
    return _orig_svd(A, full_matrices=full_matrices, driver=driver)


torch.linalg.svd = _safe_svd

from esm.models.esmfold2 import (  # noqa: E402
    EsmFold2Model, ESMFold2InputBuilder, StructurePredictionInput, ProteinInput,
)
from esm.utils.msa.msa import MSA  # noqa: E402

# ---- low-memory weight loading (REQUIRED on <32 GB RAM hosts) --------------
# esm's own read_safetensors_dir() calls safetensors.torch.load_file(), which
# materialises the WHOLE checkpoint in host RAM before anything reaches the GPU.
# ESMFold2 ships 6.58 B params in FP32 = 26.3 GB, so peak host RAM is 26 GB
# regardless of the dtype you request, and on a 16 GB box it OOMs. Passing
# dtype=torch.bfloat16 does not help: esm applies model.to(dtype) only AFTER
# `del raw`, i.e. after the peak has already been hit.
#
# Measured fix: open each shard with safetensors' device-aware reader so tensors
# land in VRAM directly and get converted there. Measured 2026-10-09 on a 64-residue
# job: host peak RSS 6.53 GB, VRAM 12.69 GB after load, 12.95 GB peak while folding.
import json as _json  # noqa: E402
from pathlib import Path as _Path  # noqa: E402
import esm.models.hub as _hub  # noqa: E402
from safetensors import safe_open as _safe_open  # noqa: E402

DTYPE = torch.bfloat16
# esm hard-codes `z = z.float()` on the pair representation before the structure
# heads, so these three must stay fp32 or F.linear raises
#   "mat1 and mat2 must have the same dtype, but got Float and BFloat16".
# They total only 0.139 B params (0.52 GB), so this costs almost nothing.
FP32_PREFIXES = ("distogram_head", "structure_head", "confidence_head")


def _read_safetensors_dir_vram(directory):
    """Stream checkpoint shards straight into VRAM; host RAM stays flat.

    Per-tensor precision: fp32 for the structure heads, bf16 for the 6.345 B
    ESMC backbone. The result is 12.5 GB of VRAM for a 24.5 GB fp32 checkpoint.
    """
    directory = _Path(directory)
    index = directory / "model.safetensors.index.json"
    if index.exists():
        with open(index) as f:
            weight_map = _json.load(f)["weight_map"]
        shards = sorted(set(weight_map.values()))
    elif (directory / "model.safetensors").exists():
        shards = ["model.safetensors"]
    else:
        raise FileNotFoundError("no safetensors checkpoint in %s" % directory)
    sd = {}
    for s in shards:
        with _safe_open(str(directory / s), framework="pt", device="cuda") as sf:
            for k in sf.keys():
                t = sf.get_tensor(k)
                want = torch.float32 if k.startswith(FP32_PREFIXES) else DTYPE
                sd[k] = t.to(want) if t.dtype != want else t
                del t
        torch.cuda.synchronize()
    return sd


_hub.read_safetensors_dir = _read_safetensors_dir_vram


def _candidate_roots():
    """Where a local snapshot may live.

    ESMFold2-Fast was moved off the D: NVMe to the E: mechanical disk on
    2026-10-09 (D: had only 16 GB free and still needs room for the ~43 GB bfd
    MSA index). Searching only /esmfold2/models made the "fast" variant silently
    miss its snapshot and fall through to the hub id, where huggingface.co is
    unreachable from this network -- so a fast job hung instead of erroring.
    """
    roots = []
    env = os.environ.get("ESMFOLD2_WEIGHTS")
    if env:
        roots.append(_Path(env))
    roots.append(_Path("/esmfold2/models"))
    roots.append(_Path("/mnt/e/protforge/models"))
    roots.append(_Path("/mnt/e/oih/models"))   # pre-rename data root
    return roots


def _weights_path(variant):
    """Resolve a local snapshot; only fall back to a hub id as a last resort."""
    name = "ESMFold2" if variant == "full" else "ESMFold2-Fast"
    searched = []
    for root in _candidate_roots():
        d = root / name
        searched.append(str(d))
        if (d / "config.json").exists():
            return str(d)
    print("[esmfold2] WARN no local snapshot for %r; searched: %s"
          % (variant, ", ".join(searched)), flush=True)
    return VARIANTS[variant]


VARIANTS = {"full": "biohub/ESMFold2", "fast": "biohub/ESMFold2-Fast"}
OUTDIR = "/esmfold2/out"

_models = {}


def get_model(variant):
    if variant not in _models:
        src = _weights_path(variant)
        print("[esmfold2] loading %s (%s)" % (variant, src), flush=True)
        t = time.time()
        # dtype MUST be None: esm runs `if dtype is not None: model.to(dtype)`
        # after load_state_dict, which re-casts every parameter to that single
        # dtype and undoes the fp32 structure heads, breaking at distogram_head.
        # Precision is decided entirely by _read_safetensors_dir_vram above.
        # Never use from_pretrained(...).cuda(): the default device="cpu" stages
        # the whole 24.5 GB checkpoint in host RAM first.
        m = EsmFold2Model.from_pretrained(src, device="cuda", dtype=None).eval()
        m.set_kernel_backend("fused")     # REQUIRED, default is ~12x slower
        m.set_chunk_size(None)
        print("[esmfold2] loaded in %.1fs" % (time.time() - t), flush=True)
        _models[variant] = m
    return _models[variant]


def main(job_path):
    job = json.load(open(job_path, encoding="utf-8"))
    name = job.get("name", "job")
    variant = job.get("variant", "full")
    msas = job.get("msa") or {}
    loops = job.get("num_loops", 10)
    steps = job.get("num_sampling_steps", 68)      # paper: 68, NOT 200
    samples = job.get("num_diffusion_samples", 5)
    seed = job.get("seed", 0)

    os.makedirs(OUTDIR, exist_ok=True)
    model = get_model(variant)

    seqs = []
    msa_requested = 0
    msa_used = 0
    for entry in job["sequences"]:
        cid = entry["id"]
        seq = entry["sequence"]
        kw = {}
        p = msas.get(cid)
        if p and variant == "full":
            msa_requested += 1
            if not os.path.exists(p):
                print("[esmfold2] WARN missing a3m %s for chain %s; running single-seq"
                      % (p, cid), flush=True)
            else:
                kw["msa"] = MSA.from_a3m(p, max_sequences=2048)
                msa_used += 1
        seqs.append(ProteinInput(id=cid, sequence=seq, **kw))
    if variant == "fast" and msa_requested:
        print("[esmfold2] WARN variant 'fast' has no MSA encoder; MSAs ignored",
              flush=True)

    spi = StructurePredictionInput(sequences=seqs)
    builder = ESMFold2InputBuilder()

    torch.cuda.reset_peak_memory_stats()
    t = time.time()
    # fold() returns a BARE MolecularComplexResult when num_diffusion_samples==1
    # and a LIST when >1 (both paths verified by probe). Normalise before ranking.
    res = builder.fold(model, spi, num_loops=loops,
                       num_sampling_steps=steps,
                       num_diffusion_samples=samples, seed=seed)
    cands = list(res) if isinstance(res, (list, tuple)) else [res]
    ranked = sorted(cands, key=lambda r: -float(
        r.iptm if getattr(r, "iptm", None) is not None else r.plddt.mean()))
    best = ranked[0]
    dt = time.time() - t
    peak = torch.cuda.max_memory_allocated() / 1024 ** 3

    cif = os.path.join(OUTDIR, name + ".cif")
    open(cif, "w").write(best.complex.to_mmcif())

    meta = {
        "name": name, "variant": variant, "cif": cif,
        "n_chains": len(seqs),
        "msa_requested": msa_requested,
        "msa_used": msa_used,
        "num_loops": loops, "num_sampling_steps": steps,
        "num_diffusion_samples": samples, "seed": seed,
        "seconds": round(dt, 1), "peak_vram_gb": round(peak, 2),
        "mean_plddt": round(float(best.plddt.mean()), 2),
        "ptm": round(float(best.ptm), 4) if best.ptm is not None else None,
        "iptm": round(float(best.iptm), 4) if best.iptm is not None else None,
        "n_atoms": int(best.num_tokens) if best.num_tokens else None,
        "n_candidates": len(ranked),
        "all_iptm": [round(float(r.iptm), 4) for r in ranked
                     if getattr(r, "iptm", None) is not None],
    }
    mp = os.path.join(OUTDIR, name + "_metrics.json")
    json.dump(meta, open(mp, "w"), indent=2)

    print("PROTFORGE_OUTPUT_DIR: %s" % OUTDIR)
    print("PROTFORGE_CIF: %s" % cif)
    print("PROTFORGE_METRICS: %s" % mp)
    print("RESULT variant=%s msa=%d/%d ipTM=%s pTM=%s pLDDT=%.1f  %.1fs  peakVRAM=%.1fGB"
          % (variant, msa_used, msa_requested, meta["iptm"], meta["ptm"],
             meta["mean_plddt"], dt, peak))
    print("PROTFORGE_STATUS: OK")


if __name__ == "__main__":
    main(sys.argv[1])
