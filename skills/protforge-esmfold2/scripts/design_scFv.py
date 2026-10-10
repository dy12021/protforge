"""ESMFold2 scFv CDR redesign — the loop that Biohub's cookbook calls `DesignApp`.

WHY THIS FILE EXISTS
--------------------
`DesignApp` is described in the Biohub cookbook but is NOT in the PyPI wheel:

    grep -rn "DesignApp" site-packages/esm/ --include=*.py   ->  0 hits

What the released checkpoint ships is the mechanism it would have been built on --
and the mechanism is NOT where the docs point.

* `EsmFold2ExperimentalModel.forward` has an explicit `res_type_soft` argument and
  `torch.set_grad_enabled(res_type_soft is not None)`. **But that class cannot load
  the checkpoint we hold.** Parsed from the AST, its `__init__` assigns 12
  attributes against `EsmFold2Model`'s 18: it builds none of the `parcae_*` modules
  and no `lm_encoder`, and adds `pair_loop_proj` instead. Our checkpoint contains
  `parcae` (42 tensors) and `lm_encoder` (72 tensors).

* The usable path is `EsmFold2Model.forward`, which already contains

        if res_type.dim() == 2:
            res_type_oh = F.one_hot(res_type.long(), num_classes=NUM_RES_TYPES).float()
            ...
        else:
            res_type_oh = res_type.float()      # <- a float [L, V] tensor IS the one-hot

  and in single-sequence mode `profile = res_type_oh`, so gradients reach both the
  `aatype` and `profile` inputs of the inputs embedder.

* The one thing in the way is the decorator:

        @torch.inference_mode()
        def forward(self, ...)

  Inference-mode tensors cannot be differentiated at all -- verified on this box:
  `RuntimeError: element 0 of tensors does not require grad and does not have a
  grad_fn`. `torch.inference_mode` uses `functools.wraps`, so the undecorated
  function is reachable as `EsmFold2Model.forward.__wrapped__` (38 parameters).
  Calling that directly restores autograd. Nothing else on the forward path is
  grad-disabled: the only other `@torch.no_grad()` in model.py sits on
  `infer_protein`, a convenience wrapper this script does not call.

WHAT IS *NOT* AVAILABLE (checked in source, do not assume otherwise)
--------------------------------------------------------------------
    StructurePredictionInput.pocket              silently dropped
        processor.clean_esmfold2_input does not forward it
        prepare_input.py: "# --- Pocket (dropped) ---"
        model.py: _IGNORED_FEATURE_KEYS contains "pocket_feature"
    StructurePredictionInput.distogram_conditioning
        raises NotImplementedError("distogram conditioning is not implemented
        for ESMFold2; fold without it.")

So you cannot pin an epitope. The design is driven purely by the score, which is
why this loop optimises interface PAE rather than trying to constrain it.

WHY NOT builder.fold()
----------------------
fold() calls the model with named arguments only, has no way to pass a float
`res_type`, and wraps the result in a MolecularComplexResult computed *after* the
forward pass, which detaches the graph. So: prepare_input(), then the undecorated
forward, directly.

MEMORY
------
Backprop through 48 pairformer layers keeps activations alive, unlike inference.
At L=64 inference peaked at 12.95 GB of a 20 GB card; design mode has far less
headroom. Start with the smoke job and treat OOM as an expected outcome rather
than a bug -- lower `steps`, shorten the target, or switch to the Fast variant.

Usage
-----
    python design_scFv.py job.json

Job JSON:
    {"name": "cdrh3_scan",
     "variant": "full",
     "target_sequence": "MV...",              # antigen, fixed
     "scaffold_sequence": "EVQLVESGG...",    # scFv (VH-linker-VL), framework fixed
     "design_positions": [217, 218, ...],     # 0-based indices into the scaffold
     "restraint_chain": "B",                  # which chain is scored vs the target
     "rounds": 8, "steps": 40, "temperature": 1.0, "seed": 0}

ALWAYS check design_positions against the residues you meant before running
(check_design_job.py.sh prints what each index resolves to). An off-by-N there
redesigns the framework instead of the CDR and this script still reports success.
"""
import json
import os
import sys
import time

import torch

# ---- must precede any folding: cusolver SVD poisoning -------------------------
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
    ESMFold2InputBuilder, EsmFold2Model, ProteinInput, StructurePredictionInput,
)

# ---- low-memory weight loading ------------------------------------------------
import json as _json  # noqa: E402
from pathlib import Path as _Path  # noqa: E402
import esm.models.hub as _hub  # noqa: E402
from safetensors import safe_open as _safe_open  # noqa: E402

DTYPE = torch.bfloat16
FP32_PREFIXES = ("distogram_head", "structure_head", "confidence_head")

AA = "ACDEFGHIKLMNPQRSTVWY"
AA_TO_IDX = {c: i for i, c in enumerate(AA)}
DESIGN_TEMP_INIT = 0.25     # initial sharpness of the design positions


def _read_safetensors_dir_vram(directory):
    """Stream shards straight into VRAM; host RAM stays flat.

    Same reason as in fold.py: esm's loader materialises all 26 GB of fp32 weights
    in host RAM before anything reaches the GPU, which OOMs a 16 GB box.
    """
    directory = _Path(directory)
    index = directory / "model.safetensors.index.json"
    if index.exists():
        with open(index) as f:
            shards = sorted(set(_json.load(f)["weight_map"].values()))
    elif (directory / "model.safetensors").exists():
        shards = ["model.safetensors"]
    else:
        # No index and no single-file checkpoint, but the shards are plainly
        # there. ESMFold2-Fast ships model-0000N-of-00006.safetensors with NO
        # model.safetensors.index.json, so the two branches above both miss and
        # the loader raised "no safetensors checkpoint in ..." on a directory
        # holding 24.3 GB of verified weights. Fall back to globbing.
        shards = sorted(p.name for p in directory.glob("*.safetensors"))
        if not shards:
            raise FileNotFoundError("no safetensors checkpoint in %s" % directory)
        print("[design] no index json; globbed %d shard(s): %s"
              % (len(shards), ", ".join(shards)), flush=True)
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


# ---- VRAM-frugal checkpoint layout conversion ---------------------------------
# esm's own conversion functions build a NEW dict while the input dict is still
# referenced, so peak VRAM is about (raw bf16 + normalised bf16). For ESMFold2
# that is roughly 12.5 + 12.5 GB and the load dies on a 20 GB card with:
#   torch.OutOfMemoryError: CUDA out of memory. Tried to allocate 68.00 MiB.
#   GPU 0 has a total capacity of 20.00 GiB of which 0 bytes is free.
#   ... Of the allocated memory 18.81 GiB is allocated by PyTorch
#
# The replacements below are semantically identical -- same name maps, same
# ordering, same ValueError on an incomplete projection set -- but they CONSUME
# their input: every key is popped as soon as it is read, and the sources of each
# torch.cat are popped immediately after the concatenation lands, so the caching
# allocator reuses those blocks instead of holding two full copies.
#
# All three call sites bind these names with `from ... import`, so patching the
# defining module alone would silently do nothing. Each binding is rebound:
#   checkpoint_layout.published_to_native            (same-module lookup)
#   hf_checkpoint.published_to_native_subtree        (from-import at line 25)
#   hf_checkpoint.hf_state_dict_to_native
#   model.hf_state_dict_to_native / .published_to_native_subtree
import esm.models.esmfold2.hf_checkpoint as _hfc  # noqa: E402
import esm.models.esmfold2.model as _f2model  # noqa: E402
from esm.models.esmc import checkpoint_layout as _cl  # noqa: E402


def _published_to_native_frugal(raw):
    out = {}
    parts = {}
    part_leaves = {leaf for leaves in _cl._FUSED.values() for leaf in leaves}
    for key in list(raw.keys()):
        value = raw.pop(key)
        prefix, rest = _cl._split_encoder_prefix(key)
        if rest in _cl._ROOT:
            out[prefix + _cl._ROOT[rest]] = value
            continue
        if key in _cl._LM_HEAD:
            out[_cl._LM_HEAD[key]] = value
            continue
        match = _cl._PUBLISHED_BLOCK.match(rest)
        if match is None:
            out[key] = value
            continue
        index, leaf = match.group(1), match.group(2)
        block = "%stransformer.blocks.%s." % (prefix, index)
        if leaf in _cl._BLOCK:
            out[block + _cl._BLOCK[leaf]] = value
        elif leaf in part_leaves:
            parts.setdefault((prefix, index), {})[leaf] = value
        else:
            out[key] = value

    for (prefix, index), found in parts.items():
        block = "%stransformer.blocks.%s." % (prefix, index)
        for fused, leaves in _cl._FUSED.items():
            present = [leaf for leaf in leaves if leaf in found]
            if not present:
                continue
            if len(present) != len(leaves):
                raise ValueError(
                    "block %s has an incomplete set of projections for %r: "
                    "found %s, need %s" % (index, fused, present, list(leaves)))
            out[block + fused] = torch.cat(
                [found.pop(leaf) for leaf in leaves], dim=0)
        found.clear()
    return out


def _published_to_native_subtree_frugal(raw, prefix):
    # Keys outside the prefix are already correctly named, so the caller's dict is
    # rewritten in place instead of being rebuilt. That alone removes one full
    # copy of the checkpoint.
    inner = {}
    for k in list(raw.keys()):
        if k.startswith(prefix):
            inner[k[len(prefix):]] = raw.pop(k)
    conv = _published_to_native_frugal(inner)
    for k in list(conv.keys()):
        raw[prefix + k] = conv.pop(k)
    conv.clear()
    return raw


def _hf_state_dict_to_native_frugal(raw):
    out = {}
    packed = {}

    def emit(key, tensor):
        if key in out:
            raise ValueError("two checkpoint tensors both map onto %r" % (key,))
        out[key] = tensor

    for key in list(raw.keys()):
        tensor = raw.pop(key)
        if key.startswith(_hfc._ESMC_PREFIX):
            emit(key, tensor)
            continue
        native = _hfc.to_native_key(key)
        order = next((o for s, o in _hfc._PACKED.items() if native.endswith(s)), None)
        if order is not None:
            part = key.rsplit(".", 2)[-2][0]
            parts = packed.setdefault(native, (order, {}))[1]
            if part in parts:
                raise ValueError(
                    "two checkpoint tensors both map onto %r" % (native,))
            parts[part] = tensor
        elif native.endswith(".a_proj.weight"):
            gate, up = torch.chunk(tensor, 2, dim=0)
            emit(native, gate.clone())
            emit(native.replace(".a_proj.", ".b_proj."), up.clone())
        else:
            emit(native, tensor)

    for native, (order, parts) in packed.items():
        if set(parts) != set(order):
            raise ValueError("%r is missing parts: %s"
                             % (native, sorted(set(order) - set(parts))))
        emit(native, torch.cat([parts.pop(p) for p in order], dim=0))
    return _published_to_native_subtree_frugal(out, _hfc._ESMC_PREFIX)


_cl.published_to_native = _published_to_native_frugal
_hfc.published_to_native_subtree = _published_to_native_subtree_frugal
_hfc.hf_state_dict_to_native = _hf_state_dict_to_native_frugal
_f2model.hf_state_dict_to_native = _hf_state_dict_to_native_frugal
_f2model.published_to_native_subtree = _published_to_native_subtree_frugal


def _resolve(roots, name):
    for r in roots:
        d = _Path(r) / name
        if (d / "config.json").exists():
            return d
    return None


def load_model(variant):
    roots = [os.environ.get("ESMFOLD2_WEIGHTS"),
             "/esmfold2/models", "/mnt/e/protforge/models",
             "/mnt/e/oih/models"]   # pre-rename data root
    roots = [r for r in roots if r]
    wname = "ESMFold2" if variant == "full" else "ESMFold2-Fast"
    wdir = _resolve(roots, wname)
    if wdir is None:
        raise FileNotFoundError("no local %s snapshot; searched: %s" % (wname, roots))
    print("[design] weights=%s" % wdir, flush=True)

    # Point the CCD lookup at a local snapshot.
    #
    # ESMFold2InputBuilder() -> load_ccd(None) -> hf_hub_download("ccd.pkl").
    # ccd.pkl is 417 MB and ALREADY EXISTS in the full snapshot (verified
    # against the remote manifest), yet the default path still fetches it from
    # huggingface.co. On a link shared with another download that stalls for
    # 28+ minutes on a 0-byte blob with no error — the run looks hung rather than
    # misconfigured. Both the env var (CCD_PICKLE_PATH) and ccd_cache are set so
    # neither the code path nor the environment can fall back to the network.
    #
    # The CCD is a chemical component dictionary, not a model artefact: it is
    # identical for every variant. ESMFold2-Fast does not ship its own copy, so
    # fall back to any local snapshot that does rather than reaching for the Hub.
    ccd = wdir / "ccd.pkl"
    if not ccd.exists():
        for root in roots:
            for cand in (_Path(root) / "ccd.pkl",
                         _Path(root) / "ESMFold2" / "ccd.pkl",
                         _Path(root) / "ESMFold2-Fast" / "ccd.pkl"):
                if cand.exists():
                    ccd = cand
                    break
            if ccd.exists():
                break
    if ccd.exists():
        os.environ["ESMCFOLD_CCD_PATH"] = str(ccd)
        print("[design] ccd=%s (%d MB)" % (ccd, ccd.stat().st_size // (1 << 20)),
              flush=True)
    else:
        raise FileNotFoundError(
            "no ccd.pkl under %s; refusing to start, because the builder would "
            "fall back to hf_hub_download for a 417 MB file that silently stalls "
            "for ~28 min at 0 bytes when the link is busy" % (roots,))

    # dtype MUST stay None: esm applies model.to(dtype) after load_state_dict,
    # which re-casts everything including the fp32 structure heads.
    model = EsmFold2Model.from_pretrained(str(wdir), device="cuda", dtype=None)
    model.eval()
    model.set_kernel_backend("fused")
    model.set_chunk_size(None)

    if not hasattr(EsmFold2Model.forward, "__wrapped__"):
        raise RuntimeError(
            "EsmFold2Model.forward has no __wrapped__; @torch.inference_mode() "
            "cannot be bypassed and no gradient can reach the sequence.")
    return model, wdir, ccd.parent


def build_features(builder, target, scaffold):
    spi = StructurePredictionInput(sequences=[
        ProteinInput(id="A", sequence=target),
        ProteinInput(id="B", sequence=scaffold),
    ])
    return builder.prepare_input(spi, device="cuda")


def chain_token_slice(features, chains, chain_id):
    """Token indices for one chain, in the order prepare_input emitted them."""
    asym = features["asym_id"][0].cpu().tolist()
    want = None
    for c in chains:
        if c.chain_id == chain_id:
            want = c.asym_id
            break
    if want is None:
        raise KeyError("chain %r not in %s" % (chain_id, [c.chain_id for c in chains]))
    return [i for i, a in enumerate(asym) if a == want]


def make_soft(target, scaffold, design_positions, num_res_types, device):
    """[1, L_total, num_res_types] float tensor replacing res_type wholesale.

    It must span the WHOLE input (target + binder), not just the binder, because
    it substitutes feats["res_type"], whose length is the assembled token count
    L = len(target) + len(scaffold). The antigen block is pinned to a hard one-hot
    and is never optimised; only the design positions are softened.

    SHAPE IS LOAD-BEARING. ESMFold2Model.forward does:

        if res_type.dim() == 2:
            res_type_oh = F.one_hot(res_type.long(), num_classes=NUM_RES_TYPES).float()
            res_type_oh = res_type_oh * tok_mask.unsqueeze(-1).float()
        else:
            res_type_oh = res_type.float()

    The integer path feeds a batched [1, L] class tensor, so dim()==2 means "these
    are class indices" and gets one-hot encoded. Passing [L, 33] -- the intuitive
    soft one-hot -- is ALSO dim 2, so it would be .long()'d and one-hot encoded a
    second time, silently producing garbage. Only dim==3 ([1, L, 33]) reaches the
    `else` branch and is used as-is, which is exactly the shape the dim==2 branch
    produces ([1, L] -> [1, L, 33]).

    The width must equal the model's NUM_RES_TYPES (33 from config), not the 20
    amino acids: the embedder is sized for the full vocabulary including the
    unknown/mask columns.
    """
    full = target + scaffold
    L = len(full)
    off = len(target)
    soft = torch.zeros(1, L, num_res_types, device=device, dtype=torch.float32)
    for i, ch in enumerate(full):
        soft[0, i, AA_TO_IDX.get(ch, 0)] = 1.0
    for p in design_positions or ():
        idx = off + p
        soft[0, idx] = 0.0
        soft[0, idx, AA_TO_IDX[scaffold[p]]] = 1.0
        soft[0, idx] = soft[0, idx] / DESIGN_TEMP_INIT   # softer start at design sites
    return soft.requires_grad_(True)


def reproject_framework(soft, full_seq, offset, design_positions):
    """Pin every non-design row back to a hard one-hot, in place on soft.data.

    full_seq is target + scaffold; `offset` is len(target), the row at which the
    binder block starts inside the [1, L, C] tensor. design_positions are
    SCAFFOLD-LOCAL indices, so they must be shifted by `offset` to address rows.

    THREE things this gets right that the first inline version did not:

    1. It walks full_seq, so the whole antigen block is pinned. The inline version
       looped over the scaffold only and left rows 0..len(target)-1 with keep=True,
       i.e. replaced by an all-zero row -- a 129-residue antigen turned into nothing.
    2. `keep` means "replace with the hard one-hot", so it starts False (free) and is
       set True only for pinned rows. The inline version started it True, which wiped
       the design positions to zero and left the framework free to drift -- exactly
       backwards.
    3. torch.where() requires a BOOL condition; a float 0/1 mask raises
       "expected condition to be a boolean tensor".
    """
    des = set(design_positions or ())
    fixed = torch.zeros_like(soft.data)
    keep = torch.zeros(1, soft.shape[1], 1, device=soft.device, dtype=torch.bool)
    for row, ch in enumerate(full_seq):
        if row >= offset and (row - offset) in des:
            continue                      # design site: leave it free
        fixed[0, row, AA_TO_IDX.get(ch, 0)] = 1.0
        keep[0, row, 0] = True
    soft.data = torch.where(keep, fixed, soft.data)


def interface_pae(pae, binder_idx, target_idx):
    """Mean PAE between two chains.

    DIFFERS FROM WHAT THIS DOCSTRING USED TO SAY. It previously claimed PAE was
    differentiable "unlike ipTM", which came from the docs rather than the source.
    The source says the opposite -- esm/models/esmfold2/model.py:332

        pae = _categorical_mean(pae_logits, start=0.0, end=32.0).detach()

    and plddt/ptm/iptm are detached at lines 390/400/401, with the head itself fed
    x_inputs.detach() and z.detach().float() at lines 1381-1382. So the whole
    confidence back-half is non-differentiable BY DESIGN, and no amount of
    bypassing @torch.inference_mode() brings a gradient back. This is what made
    design_scFv exit 5 with "loss is detached".

    The arithmetic below is still correct and still useful for reading a PAE that
    some other differentiable path produced; what is NOT correct is expecting
    autograd to flow through a PAE taken from forward()'s return dict. Use
    pae_from_logits() instead -- see the note on that function for which outputs
    survive.
    """
    p = pae
    while p.dim() > 2:          # drop any leading sample/ensemble dims
        p = p[0]
    bi = torch.as_tensor(binder_idx, device=p.device)
    ti = torch.as_tensor(target_idx, device=p.device)
    return p[bi][:, ti].mean()


def pae_from_logits(pae_logits):
    """Expected PAE from raw logits.

    DIAGNOSTIC ONLY -- DO NOT BUILD A LOSS ON THIS. The detach lives in
    model.py:332 (after the logits exist), so rebuilding the expectation is easy
    and the result carries a grad_fn. But the confidence head is fed
    z.detach().float() (model.py:1382), so that graph terminates at the head and
    the gradient never returns to res_type. Measured: |dL/d soft| = 0, versus
    598.14 for distogram_logits. Kept because it is a cheap, honest readout of how
    good the current design is; used as the objective it silently does nothing.
    """
    start, end = 0.0, 32.0
    n_bins = pae_logits.shape[-1]
    edges = torch.linspace(start, end, n_bins + 1,
                           device=pae_logits.device, dtype=torch.float32)
    v_bins = (edges[:-1] + edges[1:]) / 2
    return (pae_logits.float().softmax(-1) @ v_bins.unsqueeze(-1)).squeeze(-1)


def distogram_distances(logits, model):
    """Expected inter-residue distance in Angstrom from distogram_logits.

    distogram_logits is the ONE forward output whose graph reaches the sequence.
    It is produced inside the trunk from the live pair representation --
    model.py:1322  `self.distogram_head(z + z.transpose(-2, -3))` -- whereas every
    confidence-head output is fed a detached z. Measured on this box, 129 aa
    antigen + 23 aa binder:

        distogram_logits   |dL/d soft| = 598.14   gradient reaches the sequence
        pae_logits         |dL/d soft| = 0         no gradient

    Bin convention: the distances must come from the LIVE model, not from constants
    or from the dataclass defaults. model.py:111 binds `ch = config.confidence_head`
    and line 116 builds the bin edges from ch.min_dist / ch.max_dist -- which live
    on the CONFIDENCE head, not the structure head. The shipped ESMFold2-Fast
    config.json sets min_dist=3.25, max_dist=50.75, confidence_head.distogram_bins=39
    while structure_head.distogram_bins=64 (the head's actual logit width), whereas
    the dataclass defaults are 2.0 / 52.0 / 128. Reading the wrong one is silent:
    the loss still falls, it just optimises a rescaled distance.

    So: resolve from the loaded config with explicit fallbacks, and report what was
    used. The Angstrom figure rests on treating the logits as evenly spaced centres
    across [min_dist, max_dist]; that is a monotone linear map of the bin index,
    which is all the objective needs, but do not quote the Angstroms as calibrated.
    """
    lo, hi = _distogram_range(model)
    n_bins = logits.shape[-1]
    centres = torch.linspace(lo, hi, n_bins,
                             device=logits.device, dtype=torch.float32)
    d = (logits.float().softmax(-1) @ centres.unsqueeze(-1)).squeeze(-1)
    while d.dim() > 2:
        d = d[0]
    return d


_RANGE_CACHE = {}


def _distogram_range(model):
    """(min_dist, max_dist) from the loaded config, trying both heads."""
    key = id(model)
    if key in _RANGE_CACHE:
        return _RANGE_CACHE[key]
    lo = hi = None
    for attr in ("confidence_head", "structure_head"):
        blk = getattr(getattr(model, "config", None), attr, None)
        if blk is None:
            continue
        a, b = getattr(blk, "min_dist", None), getattr(blk, "max_dist", None)
        if isinstance(a, (int, float)) and isinstance(b, (int, float)):
            lo, hi = float(a), float(b)
            print("[design] distogram range from %s: [%.2f, %.2f] over %d logits"
                  % (attr, lo, hi, model.config.structure_head.distogram_bins),
                  flush=True)
            break
    if lo is None:
        raise AttributeError(
            "neither confidence_head nor structure_head carries min_dist/max_dist; "
            "refusing to guess a distance scale")
    _RANGE_CACHE[key] = (lo, hi)
    return lo, hi


def interface_contact_loss(logits, model, binder_idx, target_idx,
                           contact_dist=6.0, width=3.0):
    """Maximise well-formed binder-antigen contacts -- the design objective.

    The contact term is a GAUSSIAN BUMP around contact_dist, not a decreasing
    sigmoid. That distinction is the whole objective and it was got wrong first:

        sigmoid((d0 - d) / w)     -- monotone decreasing in d, so it keeps paying
                                    out as the chains squeeze together and its
                                    optimum is "collapse onto one point". On the
                                    plumbing fixture it scored 2 A at 0.0486 versus
                                    6 A at 0.3090, i.e. it preferred the collapse.

        exp(-((d - d0) / w)^2)    -- peaks at d0 and falls off both ways, so
                                    clashing (too close) and non-contact (too far)
                                    are both penalised and the objective is bounded.

    Averaging over all cross-chain pairs rather than taking the minimum keeps every
    antigen residue with a pull toward the binder.
    """
    d = distogram_distances(logits, model)
    bi = torch.as_tensor(binder_idx, device=d.device)
    ti = torch.as_tensor(target_idx, device=d.device)
    cross = d[bi][:, ti]
    bump = torch.exp(-(((cross - contact_dist) / width) ** 2))
    return -torch.log(bump.mean() + 1e-6)


def sample_sequence(soft, scaffold, offset, design_positions, temperature,
                    generator, num_res_types):
    """Discrete binder sequence from the current soft assignment.

    Design positions are sampled from the distribution (the stochastic part of the
    loop); framework positions take the argmax, so they stay pinned to the scaffold.

    `soft` is [1, L, num_res_types] over target+scaffold, so the binder block starts
    at row `offset` -- but design_positions are SCAFFOLD-LOCAL. Comparing a
    scaffold-local index against a full-length row number silently samples the
    antigen instead of the CDR and leaves the intended sites untouched, so the two
    index spaces are kept separate here: slice the binder block out first, then
    index it with the scaffold-local positions.

    Columns n_aa..num_res_types-1 are the mask/unknown vocabulary, not amino acids.
    Sampling over the full 33-wide row can draw one of them, and indexing AA with
    that id raises IndexError, so the categorical is restricted and renormalised.
    """
    des = set(design_positions or ())
    n_aa = len(AA)
    out = []
    with torch.no_grad():
        probs = torch.softmax(
            soft.detach()[0, offset:offset + len(scaffold)]
            / max(temperature, 1e-3), dim=-1)          # [len(scaffold), C]
        for p in range(len(scaffold)):
            std = probs[p, :n_aa]
            if p in des:
                total = float(std.sum())
                if total <= 0.0:
                    out.append(AA[0])
                    continue
                out.append(AA[torch.multinomial(std / total, 1,
                                                generator=generator).item()])
            else:
                out.append(AA[int(std.argmax())])
    return "".join(out)


def main(job_path):
    job = json.load(open(job_path, encoding="utf-8"))
    name = job.get("name", "design")
    target = job["target_sequence"]
    scaffold = job["scaffold_sequence"]
    pos = sorted(set(job.get("design_positions") or []))
    binder_chain = job.get("restraint_chain", "B")
    rounds = int(job.get("rounds", 8))
    steps = int(job.get("steps", 40))
    temperature = float(job.get("temperature", 1.0))
    seed = int(job.get("seed", 0))
    num_loops = int(job.get("num_loops", 4))
    # Both of these multiply the activation graph, and there is no gradient
    # checkpointing in esm to trade compute back:
    #   num_loops          re-runs the whole ESMC trunk that many times, and every
    #                      loop's activations are retained because res_type
    #                      requires grad
    #   num_sampling_steps structure-module diffusion steps, each with its own
    #                      retained block activations
    # Defaults are the paper values (4 / 68). A 20 GB card cannot hold them plus
    # 12.68 GB of weights -- observed peak 18.61 GB and OOM at round 0 step 0 --
    # so both are job-configurable and the smoke test turns them down.
    num_sampling_steps = int(job.get("num_sampling_steps", 68))
    # Bound once, here, rather than inlined at the call site. The diagnostics print
    # inside the step loop needs the same two numbers, and inlining them as
    # float(job.get(...)) arguments left them unbound -- the next run died with
    # NameError: name 'contact_dist' is not defined, after a 7.5-minute weight load.
    contact_dist = float(job.get("contact_dist", 6.0))
    contact_width = float(job.get("contact_width", 3.0))

    for p in pos:
        if not (0 <= p < len(scaffold)):
            raise ValueError("design position %d outside scaffold (len %d)"
                             % (p, len(scaffold)))

    outdir = "/esmfold2/out"
    os.makedirs(outdir, exist_ok=True)
    torch.manual_seed(seed)
    gen = torch.Generator(device="cuda")
    gen.manual_seed(seed)

    model, wdir, ccd_dir = load_model(job.get("variant", "full"))
    num_res_types = int(getattr(model.config, "num_res_types", 33))
    forward_raw = EsmFold2Model.forward.__wrapped__
    # Pass the dir that actually holds ccd.pkl so ESMFold2InputBuilder finds it
    # locally. Without this it calls hf_hub_download("biohub/ESMFold2", "ccd.pkl")
    # for a 417 MB file already on disk -- which stalls ~28 min at 0 bytes when
    # the link is busy. ccd_dir is not necessarily wdir: ESMFold2-Fast ships no
    # ccd.pkl of its own, so load_model resolves it from another snapshot.
    builder = ESMFold2InputBuilder(ccd_cache=_Path(ccd_dir))

    print("[design] num_res_types=%d | target %d aa | scaffold %d aa | designing %s"
          % (num_res_types, len(target), len(scaffold), pos), flush=True)

    current = scaffold
    history = []
    t_all = time.time()

    for rnd in range(rounds):
        # ESMFold2Model.forward takes NO seed parameter -- verified with
        # inspect.signature (37 parameters besides self; there is no `seed`,
        # `generator` or `noise`). The diffusion head's stochasticity comes from
        # the global CUDA RNG, so the only way to vary noise per round is to
        # re-seed here. Passing seed= raised
        #   TypeError: forward() got unexpected keyword argument(s) ['seed']
        # after a full 29-minute weight load.
        round_seed = seed * 1000 + rnd
        torch.manual_seed(round_seed)
        torch.cuda.manual_seed_all(round_seed)

        features, chains = build_features(builder, target, current)
        L = int(features["res_type"].shape[1])
        if len(current) + len(target) != L:
            print("[design] token count %d != %d + %d. Ligands, CCD residues or "
                  "chain splitting would break the 1:1 token<->residue assumption "
                  "this soft tensor relies on. Refusing to continue."
                  % (L, len(target), len(current)), flush=True)
            return 2
        b_idx = chain_token_slice(features, chains, binder_chain)
        a_idx = chain_token_slice(features, chains, "A" if binder_chain != "A" else "B")

        # soft must span the WHOLE input (antigen + binder), not just the binder.
        offset = len(target)
        soft = make_soft(target, current, pos, num_res_types, "cuda")
        opt = torch.optim.Adam([soft], lr=float(job.get("lr", 0.5)))
        best = {"score": -1e9, "seq": current}

        for step in range(steps):
            opt.zero_grad(set_to_none=True)
            # Return the previous step's cached blocks before building the next
            # graph. Without this the allocator keeps every round's peak reserved,
            # so round 1 OOMs on fragmentation even when each step individually
            # fits.
            torch.cuda.empty_cache()
            # Substitute the differentiable one-hot for the integer res_type.
            feats = dict(features)
            feats["res_type"] = soft
            try:
                with torch.enable_grad():
                    out = forward_raw(
                        model, **feats,
                        num_diffusion_samples=1,
                        num_loops=num_loops,
                        num_sampling_steps=num_sampling_steps,
                        include_embeddings=False,  # unfixed noise poisons the grad
                    )
            except torch.cuda.OutOfMemoryError as e:
                torch.cuda.empty_cache()
                # str(e) names the offending allocation ("Tried to allocate
                # 757.00 MiB") and its traceback names the module. Swallowing it
                # cost two 16-minute runs: peak was reported as a bare 18.61 GB
                # with nothing pointing at the structure module's atom-level IPA.
                print("[design] OOM at round %d step %d (peak %.2f GB of %.2f): %s"
                      % (rnd, step, torch.cuda.max_memory_allocated() / 1024 ** 3,
                         torch.cuda.get_device_properties(0).total_memory / 1024 ** 3,
                         str(e)[:300]),
                      flush=True)
                print("[design] num_loops=%d num_sampling_steps=%d "
                      "num_diffusion_samples=1 | Lower 'num_sampling_steps' first "
                      "-- both multiply the retained activation graph -- then "
                      "shorten the target or switch to variant 'fast'."
                      % (num_loops, num_sampling_steps), flush=True)
                return 4

            # The loss must come from distogram_logits. It is the only forward
            # output still connected to the sequence: model.py:1322 computes it
            # from the live z, while every confidence output is fed z.detach()
            # (line 1382) and comes back detached (332/390/400/401). Using "pae"
            # here looks like it works -- the loss carries a grad_fn -- and then
            # deposits exactly zero gradient on the sequence.
            logits = out.get("distogram_logits")
            if not torch.is_tensor(logits):
                print("[design] no distogram_logits in forward output: %s"
                      % sorted(out.keys()), flush=True)
                return 3

            loss = interface_contact_loss(logits, model, b_idx, a_idx,
                                          contact_dist, contact_width)
            if not loss.requires_grad:
                print("[design] loss is detached. Check that forward was NOT "
                      "called through @torch.inference_mode().", flush=True)
                return 5
            loss.backward()
            if soft.grad is None or float(soft.grad.abs().sum()) == 0.0:
                print("[design] backward produced no gradient on the soft tensor "
                      "at round %d step %d." % (rnd, step), flush=True)
                return 5
            opt.step()

            with torch.no_grad():
                # Re-project framework rows to a hard one-hot so the optimiser cannot
                # drift a scaffold it was told to keep fixed, and so the antigen block
                # -- which is never optimised at all -- cannot drift either.
                reproject_framework(soft, target + current, offset, pos)

            sc = float(-loss.detach())
            if step == 0:
                # Why this exists: the first successful run sat at loss -13.8155 for
                # every step of every round. That is the saturated "no contact"
                # value -- mean(bump) ~ 1e-6 -- so the plumbing worked and the
                # gradient arrived, but the optimiser had nothing to climb. Without
                # a readout it is indistinguishable from "converged".
                #
                # So print where the predicted cross-chain distance mass actually
                # sits. Either the interface is not being formed at this setting
                # (num_loops=1, no MSA, Fast variant), or the band is pointed at a
                # range the model never predicts -- which would make the objective
                # silently wrong rather than merely unsatisfiable.
                with torch.no_grad():
                    d = distogram_distances(logits, model)
                    bi_ = torch.as_tensor(b_idx, device=d.device)
                    ti_ = torch.as_tensor(a_idx, device=d.device)
                    cross = d[bi_][:, ti_].flatten().float()
                    qs = torch.quantile(cross, torch.tensor(
                        [0.05, 0.25, 0.5, 0.75, 0.95], device=d.device))
                    lo, hi = contact_dist - contact_width, contact_dist + contact_width
                    # Fraction actually inside the band. Multiplying the two
                    # marginals (mean(<hi) * mean(>lo)) is NOT this: for a
                    # distribution entirely below the band it gives a large
                    # non-zero number, which would hide exactly the failure this
                    # diagnostic exists to catch.
                    inband = float(((cross > lo) & (cross < hi)).float().mean())
                    print("[design] r%d cross-chain distance (n=%d): "
                          "min=%.1f p05=%.1f p25=%.1f p50=%.1f p75=%.1f p95=%.1f "
                          "max=%.1f | frac in [%.1f, %.1f] = %.4f"
                          % (rnd, cross.numel(), float(cross.min()),
                             *[float(q) for q in qs], float(cross.max()),
                             lo, hi, inband),
                          flush=True)
            if sc > best["score"]:
                best = {"score": sc,
                        "seq": sample_sequence(soft, current, offset, pos,
                                               temperature, gen, num_res_types)}
            if step % 10 == 0 or step == steps - 1:
                print("  round %d step %2d  interface_pae=%.3f  vram=%.2f GB"
                      % (rnd, step, sc,
                         torch.cuda.max_memory_allocated() / 1024 ** 3), flush=True)

        if best["seq"] != current:
            print("[design] round %d accepted (score %.3f)" % (rnd, best["score"]),
                  flush=True)
            print("           %s" % best["seq"], flush=True)
        current = best["seq"]
        history.append({"round": rnd, "score": round(best["score"], 4),
                        "sequence": current})

    meta = {"name": name, "design_positions": pos, "variant": job.get("variant", "full"),
            "target_length": len(target), "scaffold_length": len(scaffold),
            "rounds": rounds, "steps": steps, "num_loops": num_loops,
            "num_sampling_steps": num_sampling_steps,
            "peak_vram_gb": round(torch.cuda.max_memory_allocated() / 1024 ** 3, 2),
            "history": history, "final_scaffold": current,
            "elapsed_s": round(time.time() - t_all, 1)}
    mp = os.path.join(outdir, name + "_design.json")
    json.dump(meta, open(mp, "w"), indent=2)
    print("PROTFORGE_OUTPUT_DIR: %s" % outdir, flush=True)
    print("PROTFORGE_METRICS: %s" % mp, flush=True)
    print("RESULT redesigned %d position(s) in %d rounds, %.0fs"
          % (len(pos), rounds, time.time() - t_all), flush=True)
    print("PROTFORGE_STATUS: OK", flush=True)
    return 0


if __name__ == "__main__":
    # sys.exit() is load-bearing. main() signals every failure by returning a
    # non-zero code (2 token-count mismatch, 3 missing output keys, 4 OOM, 5
    # detached loss) and printing PROTFORGE_STATUS only on the success path. Calling
    # main() bare throws those return values away, so the process always exits 0:
    # observed 2026-10-09, a run that OOM'd at round 0 step 0 returned 4 and the
    # wrapper still printed DESIGN_SMOKE_OK.
    sys.exit(main(sys.argv[1]))
