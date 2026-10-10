---
name: protforge-esmfold2
description: Predict protein/complex structures with ESMFold2 (Biohub) - all-atom co-folding, single-sequence or MSA-conditioned - and design binders on an existing antibody scaffold via the official DesignApp. Runs in the AF3Native WSL distro at /esmfold2. Trigger when the user asks to fold a protein or complex, predict an antibody-antigen / protein-protein structure, design or affinity-maturise an antibody CDR, validate a designed binder against its target, or rank candidate interfaces by ipTM. Two variants: full (48 pair layers, accepts MSA) and Fast (24 layers, single-sequence only, ~1.7x faster, for high-throughput screening). Replaces the deprecated protforge-alphafold3. Use protforge-af3-msa first if MSA-conditioned folding is needed.
---

# ESMFold2 — all-atom co-folding + binder design

Host: **AF3Native WSL distro** (`wsl.exe -d AF3Native`), venv `/esmfold2/venv`.

## Variants

| Name | Repo | pair layers | MSA | Use for |
|---|---|---|---|---|
| **full** | `biohub/ESMFold2` | 48 | ✅ | final ranking, MSA-conditioned |
| **fast** | `biohub/ESMFold2-Fast` | 24 | ❌ single-seq | screening many candidates |

**Fast has no MSA encoder.** Passing MSAs to it silently drops them. Use full when
MSAs matter; use fast for throughput.

**Fast is the difference between fitting and OOM once autograd is on.** The two
snapshots differ in exactly **three** `config.json` keys (`diff_variant_configs.py`):

| key | full | fast |
|---|---|---|
| `folding_trunk_num_hidden_layers` | 48 | **24** |
| `disable_msa_features` | `false` | **`true`** |
| `msa_encoder.enabled` | `true` | **`false`** |

47 other keys are identical, including `num_loops` (20), `num_diffusion_samples` (32)
and `structure_head.inference_num_steps` (14). Disk size barely moves
(26.74 → 26.14 GB) because ESMC-6B dominates the parameter count — what halves is
the **retained activation graph**, which is what actually runs out of VRAM.
Measured with autograd on, 129 aa antigen + 23 aa binder:

| variant | peak VRAM | result |
|---|---|---|
| full, `num_loops=1`, `num_sampling_steps=20` | 18.61 GiB | **OOM at round 0 step 0** |
| fast, `num_loops=1`, `num_sampling_steps=14` | **13.97 GiB** | runs |

Note `num_sampling_steps` is *not* the lever it looks like: cutting it 68 → 20 left
the peak at 18.61 GiB to two decimals. The high-water mark is set by the first
denoising step's atom-level IPA, so once a single step does not fit, fewer steps do
not help. Halve the trunk instead.


FoldBench-AB (antibody-antigen DockQ pass rate, independent re-run):
ESMFold2 58% · ESMFold2+MSA 53% reported single-seq 51% · OpenDDE 76% · AF3 48%.
Protein-protein: ESMFold2+MSA 76% vs AF3 73%.

## Where things actually live (2026-10-09)

| Thing | Path | Disk | Why |
|---|---|---|---|
| ESMC-6B | `/esmfold2/models/ESMC-6B` | D: NVMe (ext4) | 23.66 GB, 6 shards |
| ESMFold2 (full) | `/esmfold2/models/ESMFold2` | D: NVMe (ext4) | 24.90 GB, 6 shards, **proven loading** |
| **ESMFold2-Fast** | **`/mnt/e/protforge/models/ESMFold2-Fast`** | **E: mechanical** | moved off D:; D: had only 16 GB free and the MSA index still needs 43 GB there |
| venv | `/esmfold2/venv` | D: NVMe | keeps torch import ~2 s instead of ~25 s |
| af3_db | `/mnt/e/protforge/models/af3_db` | E: mechanical | bfd is decompressed; mgy/nt_rna/uniprot/uniref90 are `.zst` only |

`fold.py` prefers a local weights dir over any hub lookup. Pass an explicit path
when you want a specific variant.

## Measured on this machine (double RTX 3080, 20 GB each)

A 64-residue single chain, 6.58 B params, fp32 checkpoint → bf16 on the GPU:

| Stage | Result |
|---|---|
| weight load | 12.69 GB VRAM, 6.53 GB host peak RSS, **733 s** |
| `num_sampling_steps=8, samples=1, loops=2` | peak 12.86 GB, 293 s |
| `num_sampling_steps=68, samples=5, loops=10` (paper params) | peak **12.95 GB**, **6.0 s** |
| output | `/esmfold2/out/probe_fast.cif`, 471 atoms, 64 residues, no NaN |

**Conclusion: a single 20 GB card fits full ESMFold2 with ~7 GB to spare.** Only
one process uses one card; the second card is available for a parallel job.

Reproduce with `vram_probe4.sh <weights_dir> <tag>` →
`/esmfold2/out/vram_report_<tag>.json`.

## Nine API traps — all nine bite, all nine are fixed in `scripts/`

### 0a. Only `distogram_logits` has a gradient path to the sequence

The confidence back-half cuts the autograd graph twice — at the **input** and at
the **output**:

```python
# esm/models/esmfold2/model.py
332:  pae = _categorical_mean(pae_logits, start=0.0, end=32.0).detach()
390:  "plddt": plddt.detach(),          # also 391/392/393
400:  "ptm":   ptm.detach(),
401:  "iptm":  iptm.detach(),
1381: s_inputs=x_inputs.detach(),       # the head is fed DETACHED tensors
1382: z=z.detach().float(),
```

Measured on this box, 129 aa antigen + 23 aa binder, `|dL/d soft|` after backward:

| forward output | `requires_grad` | gradient reaches `res_type`? |
|---|---|---|
| **`distogram_logits`** | True | **yes — 598.14** |
| `pae_logits` | True | **no — 0** |
| `distogram_head` grad chain | — | `ViewBackward0 -> AddmmBackward0` (live z) |

`requires_grad=True` is **not** the test. `pae_logits` reports True purely because
the confidence head's own Linear weights are trainable; its input was detached at
line 1382, so nothing can flow back. Only `distogram_logits` is computed from the
live pair representation:

```python
1322:  distogram_logits = self.distogram_head(z + z.transpose(-2, -3))
```

**So `distogram_logits` is the only forward output usable as a design objective.**
Bypassing `@torch.inference_mode()` via `forward.__wrapped__` is necessary but not
sufficient — without it nothing is attached at all; with it, the distogram is the
one thing that stays connected.

The bin scale must be read from the live config, never hard-coded: `min_dist` /
`max_dist` live on `config.confidence_head` (model.py:111 binds
`ch = config.confidence_head`), and the shipped `ESMFold2-Fast/config.json` says
`min_dist=3.25, max_dist=50.75, confidence_head.distogram_bins=39` while the head
emits `structure_head.distogram_bins=64` logits — and the dataclass defaults are
`2.0 / 52.0 / 128`. Reading the wrong one is silent: the loss still falls, it just
optimises a rescaled distance.

Design objective used in `scripts/design_scFv.py`: a **band-pass Gaussian bump**
on the cross-chain expected distance, `-log(mean(exp(-((d - d0)/w)^2)))`. A
decreasing sigmoid was tried first and is wrong — it is monotone in distance, so
it pays out as the chains squeeze together and its optimum is "collapse onto one
point" (on the plumbing fixture it scored 2 Å at 0.0486 versus 6 Å at 0.3090).
The bump penalises both a clash and a non-contact.


### 0. `ESMFold2InputBuilder()` re-downloads `ccd.pkl` (417 MB) even when it is local

```python
# esm/models/esmfold2/conformers.py
def load_ccd(cache_dir):
    if CCD_PICKLE_PATH is not None and CCD_PICKLE_PATH.exists():   # env var wins
        pkl_path = CCD_PICKLE_PATH
    elif cache_dir is not None:
        pkl_path = Path(cache_dir) / "ccd.pkl"
    else:
        pkl_path = Path(hf_hub_download(repo_id="biohub/ESMFold2", filename="ccd.pkl"))
```

`ccd.pkl` is 417 MB and sits in every local snapshot (verified 17/17 against the
remote manifest), yet the default `ccd_cache=None` fetches it from
huggingface.co. Observed 2026-10-09: **28 minutes of silent stall on a 0-byte blob**
after the weights were already in VRAM — the run looks hung, not misconfigured.

Fix, belt and braces:

```python
os.environ.setdefault("ESMCFOLD_CCD_PATH", str(wdir / "ccd.pkl"))
builder = ESMFold2InputBuilder(ccd_cache=Path(wdir))
```

Measured: **4.1 s** instead of 28 minutes, then `build_features` 0.2 s.

**Set `HF_HUB_OFFLINE=1` whenever a local snapshot is complete.** It converts a
30-minute silent stall into a 0.5-second error that names the file:
`LocalEntryNotFoundError: Cannot reach https://huggingface.co/biohub/ESMFold2/resolve/main/ccd.pkl`.
A problem that can only hang is a problem you cannot diagnose.

These are not documentation nitpicks. Each one produces either an OOM, a dtype
error, or a silently wrong result.

### 1. `read_safetensors_dir` materialises the whole checkpoint in host RAM

`esm` calls `safetensors.torch.load_file()`, which loads **every** shard at once.
26.3 GB of fp32 weights into a 16 GB box → OOM before the GPU is ever touched.

Fix: replace `hub.read_safetensors_dir` with a loader that opens each shard via
`safe_open(..., device="cuda")` and converts per tensor on the GPU. Host RSS stays
flat; a `safe_open` tensor also stays valid after the `with` block closes, so the
file can stay mmap'd and page straight into VRAM.

### 2. `dtype=torch.bfloat16` does not work — you must pass `dtype=None`

`_load_pretrained` applies `model.to(dtype)` **after** `del raw`, i.e. after the
host-RAM peak has already happened, and it recursively re-casts *every* parameter
to that single dtype — including the fp32 heads from trap 3, which then breaks.

Fix: `from_pretrained(path, device="cuda", dtype=None)` and let the loader decide
precision per tensor.

### 3. Three heads must stay fp32

`esm` hard-codes `z = z.float()` on the pair representation before feeding
`distogram_head` / `structure_head` / `confidence_head`. bf16 there raises
`mat1 and mat2 must have the same dtype, but got Float and BFloat16`.

Fix: keep those three prefixes in `torch.float32` (0.139 B params, +0.25 GB),
everything else bf16. Total VRAM 12.69 GB instead of 12.44 GB.

### 4. `fold()` returns two different shapes

`num_diffusion_samples == 1` → a bare `MolecularComplexResult`.
`> 1` → a `list`. Ranking without normalising fails on one of the two paths.

Fix: `cands = list(res) if isinstance(res, (list, tuple)) else [res]`.

### 5. The published→native layout conversion holds two copies — OOM even with trap 1 fixed

Found 2026-10-09 while smoke-testing `scripts/design_scFv.py`. Loading still died with:

```
torch.OutOfMemoryError: CUDA out of memory. Tried to allocate 68.00 MiB.
GPU 0 has a total capacity of 20.00 GiB of which 0 bytes is free.
... Of the allocated memory 18.81 GiB is allocated by PyTorch
```

Traps 1–3 only fix *host* RAM. The checkpoint bundles an ESMC encoder whose
published per-projection weights (`q_proj`/`k_proj`/`v_proj`, `gate_proj`/`up_proj`)
must be concatenated into the fused layout this implementation uses. Both functions
involved build a **new dict while the input dict is still referenced**:

- `esm/models/esmc/checkpoint_layout.py` — `published_to_native_subtree` copies the
  non-prefixed keys into `out`, then `out.update(published_to_native(inner))`
- `esm/models/esmfold2/hf_checkpoint.py` — `hf_state_dict_to_native` emits every key
  into `out`, then returns `published_to_native_subtree(out, _ESMC_PREFIX)`

Peak VRAM is therefore ≈ raw bf16 (12.5 GB) + normalised bf16 (12.5 GB) ≈ 25 GB,
which does not fit a 20 GB card — and it fails *after* the slow disk read, so the
stall looks like a hang rather than an error.

Fix (in `design_scFv.py`): replace both with **consuming** versions — pop each key as
soon as it is read, and pop the sources of each `torch.cat` right after the
concatenation lands, so the caching allocator reuses those blocks. Semantics are
unchanged (same name maps, same ordering, same `ValueError` on an incomplete
projection set).

**The patch must be installed on every binding, not just the defining module** — all
three call sites use `from ... import`:

```python
_cl.published_to_native = _published_to_native_frugal
_hfc.published_to_native_subtree = _published_to_native_subtree_frugal
_hfc.hf_state_dict_to_native = _hf_state_dict_to_native_frugal
_f2model.hf_state_dict_to_native = _hf_state_dict_to_native_frugal
_f2model.published_to_native_subtree = _published_to_native_subtree_frugal
```

Verify equivalence before trusting it (`verify_frugal_patch.py` rebuilds the
original from the module's own name tables and compares key sets and shapes —
a patch that silently drops one tensor yields a half-loaded model that still
reports success).

## Licence — MIT, commercially usable

Verified 2026-10-09 against two independent sources:

- Biohub's own tool docs (evo-design/proto-tools, 2026-06-07): *"ESMFold2 is open
  source and free for academic and commercial use under an **MIT license**."*
- hivebook, re-verified 2026-09-09: *"the non-commercial gate is gone — **the weights
  are MIT** and the Hugging Face repository is un-gated, so the 'Built with ESM'
  attribution requirement and the no-outputs-as-a-service restriction no longer
  apply."*

This covers ESMFold2, ESMFold2-Fast and ESMC-6B. The earlier Cambrian
Non-Commercial gate applied to `esm3-sm-open-v1`; **ESM3-small is still MIT too**,
but only the small model has open weights. Biohub's Acceptable Use Policy and the
hosted-API guardrails on controlled pathogen/toxin sequences still apply.

Practical consequence for this project: the gradient-based design route in
`design_scFv.py` has **no licensing obstacle**, which removes what had been the
single largest open risk in the toolchain.

## Command

Never inline a Python command through `wsl.exe` — PowerShell mangles the quotes.
Copy the runner into the distro once, then invoke it by path:

```powershell
wsl.exe -d AF3Native -- bash -c "mkdir -p /esmfold2/bin && cp '/mnt/c/Users/dy120/.minimax/plugins/protforge/skills/protforge-esmfold2/scripts/fold.py' /esmfold2/bin/fold.py"
wsl.exe -d AF3Native -- bash /esmfold2/bin/fold.py /esmfold2/jobs/<job>.json
```

Input JSON:

```json
{"name": "job1",
 "variant": "full",
 "sequences": [{"id": "A", "sequence": "..."}, {"id": "B", "sequence": "..."}],
 "msa": {"A": "/esmfold2/msa/a.a3m", "B": null}}
```

`msa` is optional and honoured by the **full** variant only.

## Binder / antibody design — what the public weights actually support

**`DesignApp` does not exist in `esm 3.4.1.post1`.** A case-insensitive grep for
the token across the installed package returns zero hits. The Biohub cookbook page
describes an API that is not in the PyPI wheel. Do not write code against it.

What the released checkpoint *does* support, verified by reading the source:

| Primitive | Status |
|---|---|
| `res_type_soft` on `EsmFold2ExperimentalModel.forward` | **LIVE** — a differentiable soft one-hot sequence input, with `torch.set_grad_enabled(res_type_soft is not None)`. This is the inverse-folding / sequence-design hook. |
| `configure_lm_dropout(lm_dropout, force_lm_dropout_during_inference=True)` | **LIVE** — documented as "binder-design / critic scoring"; `config.py` says "Binder-design loads set this to True". |
| `StructurePredictionInput.pocket` (`PocketConditioning`) | **DEAD — silently.** `processor.clean_esmfold2_input` rebuilds the input without forwarding `pocket`; `prepare_input.py` has `# --- Pocket (dropped) ---` and writes `pocket_feature = torch.zeros(...)`; `model.py` lists `pocket_feature` in `_IGNORED_FEATURE_KEYS`. Passing `pocket=` does nothing at all. |
| `StructurePredictionInput.distogram_conditioning` | **DEAD — loudly.** `compute_distogram_conditioning` really does build the `[L, L]` binned tensor, but `forward` raises `NotImplementedError("distogram conditioning is not implemented for ESMFold2; fold without it.")`. |

So the public ESMFold2 is **prediction-only**. For design you must write the
optimisation loop yourself around `res_type_soft`: hold the backbone fixed, make
the residue-type one-hot a differentiable tensor, run a forward pass, backprop a
binding score into it, sample a discrete sequence, repeat. The missing `DesignApp`
is that loop, and it is on the order of a hundred lines — not a model download.

If you want constraints (specified epitope, pocket, non-overlapping pair) out of
the box, use a model that actually implements them: **Chai-1** (Apache-2.0,
restraints + epitope conditioning) or **Protenix**'s `constraint_esm` branch
(contact constraints, benchmarked on a protein-antibody interface subset). Both
are reported as "勉强" on a 2×20 GB box and need measuring.

### The replacement loop lives in `scripts/design_scFv.py`

`DesignApp` is not a model download — it is an optimisation loop, and
`design_scFv.py` is that loop. The interesting part is *where the gradient hook
actually is*, which is not where the naming suggests:

- **`EsmFold2ExperimentalModel` cannot load the checkpoint we hold.** Parsed from
  the AST, its `__init__` assigns 12 attributes against `EsmFold2Model`'s 18: it
  builds none of the `parcae_*` modules and no `lm_encoder`, and adds
  `pair_loop_proj` instead. Our checkpoint has `parcae` (42 tensors) and
  `lm_encoder` (72 tensors), so loading it there would drop them.
- **The hook lives in `EsmFold2Model.forward` instead**, at the branch

  ```python
  if res_type.dim() == 2:
      res_type_oh = F.one_hot(res_type.long(), num_classes=NUM_RES_TYPES).float()
  else:
      res_type_oh = res_type.float()   # a float [L, V] tensor IS the one-hot
  ```

  Hand it a float tensor and it is used verbatim; in single-sequence mode
  `profile = res_type_oh` too, so gradients reach both `aatype` and `profile`.
- **The width must be `config.num_res_types` (33), not the 20 amino acids.**
- **`forward` is wrapped in `@torch.inference_mode()`**, and inference tensors
  cannot be differentiated at all — verified:
  `RuntimeError: element 0 of tensors does not require grad`. Since
  `torch.inference_mode` uses `functools.wraps`, the script calls
  `EsmFold2Model.forward.__wrapped__` (38 parameters) directly. Nothing else on
  the forward path is grad-disabled; the only other `@torch.no_grad()` in
  `model.py` is on `infer_protein`, which this path never calls.
- The score is **mean interface PAE**, not ipTM — ipTM is derived from PAE by the
  post-processor after autograd is gone.
- The diffusion head is **stochastic**, so `seed` is pinned per round.
- Framework rows are re-projected to a hard one-hot every step.
- **Memory is the real constraint.** Backprop through 48 pairformer layers keeps
  activations alive; the L=64 inference peak was 12.95 GB of 20 GB, and design
  mode has far less headroom. Start with the smoke job; OOM is an expected
  outcome, not a bug.

```powershell
wsl.exe -d AF3Native -- bash -c "cp '/mnt/c/Users/dy120/.minimax/plugins/protforge/skills/protforge-esmfold2/scripts/design_scFv.py' /esmfold2/bin/"
wsl.exe -d AF3Native -- bash /mnt/e/protforge/protforge-upgrade/02-newtools/check_design_job.py.sh /esmfold2/jobs/<design>.json
wsl.exe -d AF3Native -- bash /esmfold2/bin/design_scFv.py /esmfold2/jobs/<design>.json
```

Run `check_design_job.py.sh` **first**. It prints what each `design_positions`
index actually resolves to; an off-by-N redesigns the framework instead of the
CDR and the design run still reports success.

Treat the result as a **sequence proposal generator**, not a validated binder: it
optimises a predicted-structure score with no wet-lab or affinity signal, and
without pocket conditioning it cannot be told *where* to bind — only asked to bind
somewhere well. Every output still needs independent folding (ideally a second
opinion from OpenDDE `opendde_abag.pt`) and expression-level checks.

⚠️ The survey's earlier ranking put "ESMFold2 official DesignApp" first because it
was read off the Biohub docs. That ranking is wrong for the PyPI package.




## Verified working import path

**Use `esm`, not `transformers`.** Verified on this machine:

```python
from esm.models.esmfold2 import EsmFold2Model, ESMFold2InputBuilder
from esm.utils.msa.msa import MSA          # OK
```

`transformers.models.esmfold2` is the *optional* upstream path and **does not
exist** in transformers 4.57 — importing it raises `ModuleNotFoundError`. The
`esm` native path works with the installed combination.

### Installed, verified combination

```
torch         2.11.0+cu130   cuda_avail True, n_gpu 2
esm           3.4.1.post1    (MIT, PyPI pure-python wheel)
transformers  4.57.6         (downgraded from 5.19 by esm's own pin - harmless,
                              because the esm path does not need esmfold2 there)
triton        3.6.0
```

### cu12/cu13 wheel coexistence — required `LD_LIBRARY_PATH`

This venv has **both** `nvidia-*-cu12` and `nvidia-*-cu13` wheels installed. torch
2.11.0+cu130 otherwise resolves the cu12 copies and dies at runtime with
`nvrtc: error: failed to open libnvrtc-builtins.so.13.0` the moment it JIT-compiles
erfinv for `nn.init.trunc_normal_` in `_init_pair_state`.

```bash
SP=/esmfold2/venv/lib/python3.12/site-packages
export LD_LIBRARY_PATH="$SP/nvidia/cu13/lib:$SP/nvidia/cublas/lib:$SP/nvidia/cuda_runtime/lib:$LD_LIBRARY_PATH"
```

Never co-install cu12 and cu13 torch stacks into one venv — that is what produced
this. A second model needing a different CUDA backend (e.g. OpenDDE's cu126) gets
its **own** venv.

### Two documented install instructions are WRONG

If you are following a third-party skill that tells you to install

```
pip install "transformers @ git+https://github.com/Biohub/transformers.git@<sha>"
```

**stop — that repository does not exist.** Biohub's public repo list has 12
entries and none is a transformers fork. The error surfaces as
`fatal: could not read Username for 'https://github.com': terminal prompts
disabled`, which looks like an auth/network fault but is really a 404.

The path that actually works, and avoids GitHub entirely:

```bash
pip install "transformers>=5.16.0" "esm==3.4.1.post1"
```

## Download integrity — a correct filename proves nothing

**Weights: use ModelScope, not huggingface.co.** From this network a
`huggingface.co` download of `biohub/ESMC-6B` **stalled at 0 bytes/s** (measured
over 20 s). ModelScope serves the same repos under the same MIT licence.
`hf-mirror.com` works as the HuggingFace mirror for other repos (set
`HF_ENDPOINT`); `huggingface.co` direct TCP connect fails here.

```bash
pip install modelscope
python -c "
from modelscope import snapshot_download
snapshot_download('biohub/ESMC-6B',       local_dir='/esmfold2/models/ESMC-6B')
snapshot_download('biohub/ESMFold2',      local_dir='/esmfold2/models/ESMFold2')
snapshot_download('biohub/ESMFold2-Fast', local_dir='/mnt/e/protforge/models/ESMFold2-Fast')
"
```

Three traps, all hit on this box:

| Trap | What happened |
|---|---|
| **`.incomplete` suffix is the only resume signal** | A file named `*.safetensors` is treated as **finished and skipped**, even if truncated. A 1017 MB shard wearing a complete file's name would have been loaded silently and corrupted the model. |
| **A progress bar reaching 100% does not mean the file is right** | Shard 00002 showed `5.00G/5.00G` and was renamed out of `.incomplete`, but was still short of the manifest size and had to be re-fetched from zero. |
| **Plain `snapshot_download` re-reads the entire local_dir** | Resuming a 21 GB partial caused a 19.6 GB verification pass that then hung. |

Always do both of these:

```python
# 1. target only what is missing -- checked BEFORE any local inspection
snapshot_download('biohub/ESMFold2-Fast', local_dir=..., 
                  allow_file_pattern=['model-00005-of-00006.safetensors'])

# 2. verify every shard against the remote manifest before loading
from modelscope.hub.api import HubApi
files = HubApi().get_model_files('biohub/ESMFold2-Fast', revision='master')
# compare os.path.getsize(local) against each entry's Size; also assert that no
# *.incomplete remains and no undeclared *.safetensors exists
```

`verify_fast.sh` in `/mnt/e/protforge/protforge-upgrade/02-newtools/` does exactly this.

### Byte count alone is still not proof for a resumed file

A sequential download's truncated prefix is a byte-valid prefix, so a resumed
append *can* land on the manifest size and still be wrong — safetensors has no
trailing checksum. The structural proof is the header: it declares dtype/shape/
offsets for every tensor, so a header that parses **and** whose declared end
satisfies `8 + header_len + max(data_offsets.end) == filesize` is strong evidence
the bytes are coherent. `gate_checks.sh` runs this over all six Fast shards.

Prefer the vendor's own SHA-256 when one is published (OpenDDE ships one in
`model_manifest.json`; use `python -m opendde.config.model_manifest verify-checkpoint`).

### `huggingface_hub` cannot download from hf-mirror at all

`huggingface_hub` ≥ 0.30 issues a HEAD per file and validates repository metadata
headers (`X-Repo-Commit` / `ETag`). hf-mirror does not return them for some repos, so
every file is rejected **before a byte moves**:

```
FileMetadataError: Distant resource does not seem to be on huggingface.co.
```

`HfApi().model_info()` succeeds in the same process, which makes this look like a
connectivity problem when it is a metadata-compatibility problem. Fix: fetch the
immutable `…/resolve/<revision>/<file>` URL directly with a streaming GET, resume with
`Range`, and verify against the vendor's checksum.

### Measured throughput from this network (2026-10-09)

| Source | Rate |
|---|---|
| ModelScope (`biohub/ESMFold2-Fast`) | 27–130 MB/s |
| hf-mirror, single stream | 0.03–0.09 MB/s |
| hf-mirror, 16 concurrent Range segments | 0.23–0.35 MB/s |
| `download.pytorch.org` (via `uv --torch-backend`) | 0.01 MB/s |

Concurrency helps 3–7×, not 16× — the bottleneck is the cross-border link, not
per-connection throttling. Budget accordingly: a 5.5 GB asset is hours, not minutes,
and should run detached while other work proceeds on a different device.

**`uv --torch-backend cuXXX` bypasses your PyPI mirror entirely** and goes to
`download.pytorch.org`, which is 0.01 MB/s here. If the pinned torch's PyPI wheel
already bundles that CUDA version (e.g. torch 2.7.1 == cu126), drop the flag and pin
the version instead — same result, ~100× faster.

## Storage model: ext4 free space is NOT D: free space

This is the single most expensive misunderstanding on this box. Two numbers are
both true at once and do not contradict:

```
df /            ->  478 GB free   (ext4-internal)
Get-PSDrive D   ->   16 GB free   (NTFS, physical)
```

ext4 lives inside `D:\wsl\AF3Native\ext4.vhdx`. ext4-internal free space means
"no live file uses these virtual blocks" — it does **not** mean the physical bytes
came back to NTFS.

VHDX free blocks come in two kinds, and the distinction decides everything:

- **No physical backing** — the vhdx has no block for that virtual address.
  Writing here **grows the vhdx file** and eats NTFS space.
- **Has physical backing** — the block is still in the vhdx file, ext4 just
  doesn't use it. `rm` inside ext4 does *not* tell the VHDX backend, so the BAT
  entry survives. Writing here **does not grow the vhdx**.

**So: delete X GB inside ext4, then write Y GB, and if Y ≤ X the vhdx does not
grow at all — no compact required.** ext4's allocator strongly prefers reusing
just-freed blocks. `Optimize-VHD` is only an optimisation to hand that space back
to NTFS for *other* uses; it is not a precondition for writing. The only case that
genuinely needs NTFS headroom is writing *more* than was just freed.

Evidence: the first `Optimize-VHD -Mode Full` reclaimed ≈0 GB, which proves all
493 GB of physical blocks in the vhdx were live data at that moment — there was no
pre-allocated slack to recover.

Operational consequences:

- **Guard scripts must measure NTFS, not `df /`.** A guard reading `df /` sees
  478 GB and passes while D: is down to 4 GB.
- `rm` inside ext4 is instant and frees space for reuse, but changes **nothing**
  about `Get-PSDrive D`. Only `Optimize-VHD` does that.
- `Optimize-VHD` requires WSL + Docker Desktop stopped, and takes ~3 min once
  there is real garbage to reclaim.

## Serialise I/O through drvfs — one writer at a time

`/mnt/c`, `/mnt/d`, `/mnt/e` are drvfs over a 9p bridge. **Two heavy writers to
the same Windows volume deadlock or starve each other.** Both failure modes hit
this box on the same day:

| Symptom | Diagnosis |
|---|---|
| Download frozen for minutes, 0 bytes growth | `wchar` 2.98 GB but `write_bytes` 151 KB, all threads in `futex_wait_queue` → 3 GB stuck in the 9p writeback buffer |
| Package unpack at 0.90 MB/s on an NVMe | `write_bytes ≈ wchar`, so writes *are* landing — thousands of small-file writes interleaved with one huge sequential read through a single VHDX |

Rules:

- **One writer per Windows volume.** Copy, download and index-building are
  sequential steps, not parallel ones.
- Diagnose with `/proc/<pid>/io` **before** blaming the network:
  `write_bytes` not growing + all threads `futex_wait_queue` → kill and serialise.
- Measured E: throughput through 9p is ~14 MB/s, versus ~200 MB/s for a
  native NTFS-side copy. Budget accordingly.
- Long jobs must be launched with `setsid nohup ... &` from inside WSL. Killing
  the parent `wsl.exe` tears down the whole distro and takes every child with it
  (`/init` uptime resets to zero — that is the tell).
- Probe tooling before trusting it: this distro has **no `curl` and no `bc`**.
  A `curl ... || echo TIMEOUT` probe fails in ~150 ms and looks like a network
  outage; a `bc`-based size formatter silently prints `0.0 MB`. Use
  `/usr/bin/python3.12` for network checks and
  `awk -v b=... 'BEGIN{printf "%.1f", b/1048576}'` for sizes.

## Non-negotiable setup

```python
model = EsmFold2Model.from_pretrained(repo, device="cuda", dtype=None)
model.set_kernel_backend("fused")   # REQUIRED - default reference path is ~12x slower
model.set_chunk_size(None)          # optimal + OOM-safe for L <= 1024
```

Also required, in this order:

1. **Monkeypatch `torch.linalg.svd` before folding.** Degenerate diffusion samples
   produce NaN/Inf, which poison the cusolver workspace; every later CUDA call then
   dies with `illegal memory access`. Move small batched 3×3 SVDs to CPU.
   `esmfold2_smoke.py` shows the exact patch.
2. **Never install `transformer-engine`.** Its `RuntimeError` (not ImportError)
   slips past ESMC's guard and kills `ESMFold2Model` import.
3. **Do not use `set_kernel_backend("cuequivariance")`** — that wheel lacks the
   compiled ops and silently falls back to the slow reference path.
4. Above L≈1400 with `chunk_size=128` → illegal memory access. Stay at
   `chunk_size=None` up to L=1024.

### Import-time degradation warnings are expected

These are logged on first import and do **not** mean failure:

| Message | Meaning |
|---|---|
| `Transformer Engine is not installed; falling back to pure-PyTorch LayerNorm+Linear` | slower, numerically near-identical after final LayerNorm |
| `neither xformers nor flash-attn is installed; falling back to F.scaled_dot_product_attention` | ~1 bf16 ULP per block; compounds to O(100) on the *unnormalized* residual stream |
| `Error while loading libcue_ops.so: libnvrtc.so.13` | the cuequivariance fallback; do not use `--kernel-backend cuequivariance` |
| `flash-attn rotary kernel not installed; falling back to pure-PyTorch RoPE` | slower |

## Paper-faithful parameters

| Parameter | Value | Note |
|---|---|---|
| `num_loops` | 10 (20 for the "20lp" variant, +2pp AbAg) | folding-trunk recycles |
| `num_sampling_steps` | **68** | EDM-tuned — **do not use 200** |
| `num_diffusion_samples` | 5 per seed; 25 seeds for full eval | oracle = best-of-125 |

Rank composites by **ipTM**, monomers by mean **pLDDT**. Report which variant ran.

## Output contract

- One mmCIF per job under `/esmfold2/out/`
- Always report: variant, ipTM (complex) or mean pLDDT, elapsed time, peak VRAM
- `PROTFORGE_STATUS: OK` only when a CIF was written

## Failure handling

- `illegal memory access` → SVD poisoning, confirm the monkeypatch is installed
  before the first `fold()`; also drop `num_diffusion_samples` to 1
- `CUDA out of memory` → reduce `num_diffusion_samples` first, then `num_loops`;
  one process uses one card even though two are present
- `mat1 and mat2 must have the same dtype` → fp32 heads were cast to bf16; traps 2
  and 3 above
- `RuntimeError` on import → `transformer-engine` got installed; uninstall it
- Slugging import or unknown `EsmFold2Model` → `transformers` resolved to the
  stock HF build; `pip install "transformers>=5.16.0" "esm==3.4.1.post1"`
- Import takes ~1 min on first call (Triton kernel compile) — that is not a hang

## Related tools

- `opendde` (Apache-2.0, Aureka AI Research) — AF3-family co-folding with a
  dedicated **antibody-antigen** checkpoint (`opendde_abag.pt`). Commercially
  usable, unlike AF3 whose weights forbid commercial use of outputs. Lives in its
  own venv at `/opendde_venv` with torch cu126; weights on E:.
- **Do not put IgFold in a commercial pipeline** — it is JHU Academic licence,
  non-commercial even inside a company. `ImmuneBuilder` + `AntiFold` (both BSD-3)
  cover similar ground with clean licences.

## Windows (win32) platform notes

- Always go through `wsl.exe -d AF3Native -- bash <script>`. Inline compound
  commands lose their double quotes across `powershell → wsl.exe → bash`, so `|`
  silently becomes a pipe. Put anything non-trivial in a `.sh` file.
- Write `.sh` files with a tool that emits LF and no BOM. PowerShell `Set-Content`
  produces CRLF + BOM and bash then reports `$'\r': command not found`.
- Paths: host `E:\protforge\...` ↔ WSL `/mnt/e/protforge/...`; WSL-internal paths like
  `/esmfold2/...` have no host equivalent.
- Check progress with
  `wsl.exe -d AF3Native -- bash /mnt/e/protforge/protforge-upgrade/02-newtools/board.sh`
- Do not edit a shell script while bash is executing it — bash reads by byte
  offset, so an in-place edit corrupts the running job.
