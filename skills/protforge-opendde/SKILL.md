---
name: protforge-opendde
description: Predict biomolecular complex structures with OpenDDE (Aureka AI Research) - Apache-2.0 all-atom co-folding, the strongest open model on antibody-antigen complexes (FoldBench-AB 76.1% vs AlphaFold3 47.9% on independent re-runs). Runs in the AF3Native WSL distro and reuses the AlphaFold 3 genetic database at /db instead of re-downloading. Trigger when the user asks for antibody-antigen or protein-protein co-folding, wants the highest-accuracy open complex predictor, or needs the opendde_abag antibody-antigen-tuned checkpoint. Use protforge-af3-msa first when template or MSA features are wanted.
---

# OpenDDE — all-atom co-folding

Host: **AF3Native WSL** (`wsl.exe -d AF3Native`). Licence **Apache-2.0** —
commercial use OK.

| Thing | Path (verified 2026-10-11) |
|---|---|
| CLI | `/opendde_venv/bin/opendde` (package 1.2.0, Python 3.11, cu126) |
| weights + CCD assets | `$OPENDDE_ROOT_DIR` → `export OPENDDE_ROOT_DIR=...` |
| checkpoint manifest | `/opendde_venv/lib/python3.11/site-packages/opendde/config/model_manifest.json` |

Earlier revisions of this skill pointed at `/esmfold2/venv` and
`OPENDDE_ROOT_DIR=/esmfold2/opendde`. Neither is right any more: the venv was
moved to its own `/opendde_venv` so it does not share a CUDA runtime with
ESMFold2 (cu130), and the weights live on `E:`. **Never** point
`OPENDDE_ROOT_DIR` at a directory that lacks `common/components.cif` — the code
then silently downloads it from `huggingface.co`, which is TCP-refused on this
box, and the run dies looking like a model failure.

## Checkpoints

| Name | Purpose |
|---|---|
| `opendde_v1` | general-purpose (default) |
| **`opendde_abag`** | **antibody-antigen tuned** — use for antibody work |

## AF3 database compatibility (verified)

OpenDDE's `docs/msa_template_pipeline.md`:

> The default download source is the **AlphaFold v3.0 `.fasta.zst` archives**

All four files it consumes are symlinked from `/db` at install time:

| File | Used for | Size |
|---|---|---|
| `pdb_seqres_2022_09_28.fasta` | template search (hmmsearch) | 220 MB |
| `rfam_14_9_..._rep_seq.fasta` | RNA MSA | 220 MB |
| `nt_rna_2023_02_23_..._rep_seq.fasta` | RNA MSA | 75 GB |
| `rnacentral_active_..._linclust.fasta` | RNA MSA | 13 GB |

It does **not** need AF3's ~200 GB of protein-MSA files (bfd / uniref90 /
mgy_clusters / uniprot_all) for templates or RNA — those serve AF3's own
pipeline only.

**Protein MSA no longer has to leave the machine.** OpenDDE's MSA client
(`opendde/data/msa/msa_service_client.py`) posts to `https://api.colabfold.com`
by default and there is no way to point it at a local database — the only knob
is `MMSEQS_SERVICE_HOST_URL`, which expects a *server* speaking the ColabFold
protocol, not a directory of FASTA.

So do not try to configure it. **Generate the a3m locally and hand OpenDDE the
path**: `protforge-af3-msa` reads AF3's own `/db` with AF3's own jackhmmer
wrapper and writes `unpairedMsaPath` into the job JSON. Set `unpairedMsaPath`
only; OpenDDE derives the paired (query-only) alignment itself, which is exactly
what `search_and_build_msa` does when its paired ColabFold call fails.

## Command

```bash
export OPENDDE_ROOT_DIR=$OPENDDE_ROOT_DIR
export PATH=/opendde_venv/bin:$PATH
opendde pred -i job.json -o /opendde_msa_test/out \
  --load_checkpoint_path $OPENDDE_ROOT_DIR/opendde_abag.pt \
  --use_msa true --use_template false --sample 1 --step 200 --cycle 10 --device cuda
```

`-n/--name` only accepts `opendde_v1`. The antibody-antigen checkpoint is a
separate file and is selected with `--load_checkpoint_path`. Passing
`-n opendde_abag` is rejected.

Other subcommands: `opendde doctor` (verify Python/CUDA/kernels),
`opendde json` (PDB/CIF → job JSON), `opendde msa` / `mt` / `prep` (MSA,
MSA+template, +RNA).

Input JSON is a **top-level list** of jobs, each with `sequences` entries
(`proteinChain`, `dnaSequence`, `rnaSequence`, `ligand`, `ion`) and optional
`covalent_bonds`:

```json
[{"sequences": [
   {"proteinChain": {"sequence": "...", "count": 1,
                     "unpairedMsaPath": "/msashared/consumer/chain_0.a3m"}}]}]
```

Generate and inject that path in one step (searches `/db`, validates, rewrites
the job):

```bash
/alphafold3_venv/bin/python <tools-dir>/wire_opendde_msa.py \
  --job job.json --out job_msa.json --dbs uniref90,bfd
```

## Environment overrides

```bash
export OPENDDE_SEARCH_DATABASE_URL=<root>       # or the per-file ones:
export OPENDDE_PDB_SEQRES_URL=...
export OPENDDE_RFAM_DB_URL=...
export OPENDDE_NT_RNA_DB_URL=...
export OPENDDE_RNACENTRAL_DB_URL=...
```

## Installing OpenDDE from this network

Use the aliyun PyPI mirror — direct `pypi.org` measured TTFB 11.1 s from this
machine vs 0.3 s for aliyun (37x):

```bash
export UV_DEFAULT_INDEX="https://mirrors.aliyun.com/pypi/simple/"
export UV_INDEX_URL="$UV_DEFAULT_INDEX"
uv pip install --python /opendde_venv/bin/python --link-mode=copy opendde
```

**Never run two `uv pip install` against the same venv.** A killed second
install leaves the venv lock corrupted and the first one deadlocks with every
thread in `futex_wait_queue`.

Two checkpoints are auto-downloaded on first use — `opendde_v1` (general) and
`opendde_abag` (antibody-antigen tuned). If the default download endpoint stalls,
set `PROTO_MODEL_CACHE` to a path and pre-fetch; same stall was observed on
huggingface.co and did not occur via a domestic mirror.

## Reading the result

Reported metrics: per-residue **pLDDT**, global **pTM**, interface **ipTM**,
**gPDE** (global predicted distance error), plus a ranking score used to pick the
best of `num_samples`.

**Rank antibody-antigen candidates by ipTM.** Prefer `opendde_abag` for anything
antibody-shaped.

## Known limitation

On **protein-ligand** co-folding OpenDDE scores ~0.601, below AlphaFold3 (0.649)
and Protenix-v1 (0.625). Its advantage is concentrated in antibody-antigen.
Do not present it as a universal upgrade.

## Failure handling

- Model auto-download on first use → set `PROTO_MODEL_CACHE` or pre-fetch.
- `illegal memory access` → lower `--sample`; multi-GPU Fold-CP needs
  `--trimul_kernel torch --triatt_kernel torch`.
- Missing template mmCIF → `--use_template false`, or allow PDBe fetch.
- Long inputs → Fold-CP, 1×P topology, `torchrun --nproc_per_node P` where P is
  your GPU count (2 here).

## Windows (win32) platform notes

- Invoke via `wsl.exe -d AF3Native -- bash <script> <args>`.
- Bind nothing from `E:` for the search DB — it already lives at `/db` inside the
  distro.
