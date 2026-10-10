---
name: protforge-rfdiffusion
description: |
  De novo protein backbone design with RFdiffusion (container protforge-rfdiffusion) - binder
  backbones against hotspot residues, motif scaffolding, symmetric assemblies,
  partial diffusion. Trigger when the user wants to design a binder/backbone
  ("设计结合蛋白骨架", "binder design", "backbone generation", "从头设计骨架"),
  scaffold a motif, or condition generation on hotspots. NOT for sequence
  design (use protforge-proteinmpnn) or for validation (use protforge-alphafold3).
---

> Note: `${PLUGIN_DIR}` is the absolute install path of this plugin. Resolve it
> from the plugin context and substitute before invoking the command below.

# RFdiffusion — backbone generation

Runs RFdiffusion in the `protforge-rfdiffusion` container. Weights are expected at
`$PROTFORGE_MOUNT/models/rfdiffusion` inside the container; the script probes the
`vol_protforge_models` volume first, then the legacy `vol_oih_models` volume, and
falls back to the host path `$PROTFORGE_MODELS/rfdiffusion`.

## Inputs to collect

- **Target structure** — `.pdb` in `$PROTFORGE_DATA/inputs/` or an absolute host path.
  This skill does **not** produce the target; get it from `protforge-alphafold-db`
  (accession) or the user's own file.
- **Hotspot residues** — e.g. `A71,A74,A75`. More than ~6 over-constrains the
  design; 3–5 clustered within ~10 Å works best. Omit only for unconditional
  design.
- **Contig** — `contigmap.contigs`. For a binder: `[<target>/0 60-80]`, where the
  trailing range is the binder length in residues.
- **Number of designs** — `inference.num_designs`.

## Command

```bash
bash "${PLUGIN_DIR}/skills/protforge-rfdiffusion/scripts/rfdiffusion.sh" \
  "$target_pdb" "$job_name" "$contig" "$hotspots" "$num_designs"
```

- `$target_pdb` — absolute host path or filename under `inputs/`
- `$contig` — e.g. `A27-192/0 60-80` (quote it; the `/0` chainbreak is required
  so the binder is not fused to the target)
- `$hotspots` — e.g. `A71,A74,A75`; pass `none` for unconditional design

The script prints `PROTFORGE_STATUS:` and the output directory. Output lands in
`$PROTFORGE_DATA/outputs/<job_name>_rfdiffusion/`, one PDB per design named
`rfd_<n>.pdb`, plus `designs.csv`.

## Reading the result

Output directory contains:

- `rfd_*.pdb` — backbones only, **no sequence yet** (chain B is the new binder)
- `designs.csv` — per-design metadata (`rfd_score`, secondary-structure content)
- `motifs/` — sampled motif PDBs when a motif was constrained

**RFdiffusion emits no sequence.** The next hop is always `protforge-proteinmpnn`:

```bash
bash "${PLUGIN_DIR}/skills/protforge-proteinmpnn/scripts/proteinmpnn.sh" \
  "$backbone_pdb" "B" 16 "0.1" "$job_name"
```

`sampling_temp` matters more than it looks: at `0.1` ProteinMPNN heavily favours
low-complexity, alanine-rich sequences that predict well but often fail to
express. Use `0.2`–`0.3` when the designs will actually be made in the wet lab,
and filter on amino-acid composition afterwards.

## Validation hop

Backbones need an interface check before they are worth ordering:

```bash
bash "${PLUGIN_DIR}/skills/protforge-alphafold3/scripts/af3.sh" ...
```

Report `ipTM` from the `summary_confidences_*.json`. **Do not rank by ipTM
alone** — alanine-rich designs score high while making no specific contacts.
Always confirm interface coverage against the intended hotspots.

## Parallelism

`protforge_exec` picks the freest GPU per call, so sequential invocations all land
on the same card. `rfdiffusion.sh` takes an optional sixth argument — the 0-based GPU
slot — and selects the Nth freest card instead:

```bash
bash "${PLUGIN_DIR}/skills/protforge-rfdiffusion/scripts/rfdiffusion.sh" \
  "$target_pdb" "$job" "$contig" "$hotspots" 20 1     # run on the 2nd GPU
```

## Failure handling

- `FAIL input not found: E:/protforge/data/inputs/x` — put the file in `inputs/` or
  pass an absolute host path.
- `CUDA out of memory` — lower `inference.batch_size_middle` or run on the
  other GPU.
- Designs are produced but look like extended loops — the hotspot set is
  scattered; cluster it more tightly.

## Examples

Input: "对 rat EPO 的 71-79 表位设计 20 个结合蛋白骨架"

```bash
bash "${PLUGIN_DIR}/skills/protforge-rfdiffusion/scripts/rfdiffusion.sh" \
  "$PROTFORGE_DATA/inputs/ratepo_mature.pdb" "ratepo_e71" "A27-192/0 60-80" "A71,A74,A75" 20
```