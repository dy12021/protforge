---
name: protforge-alphafold3
description: DEPRECATED (2026-10-07) - superseded by protforge-esmfold2 / protforge-opendde, which score higher on antibody-antigen complexes and are permissively licensed. Do NOT route new work here. Predict protein/RNA/DNA/ligand complex structures with AlphaFold 3 (container protforge-alphafold3, models + databases on E:) Trigger: When the user asks for AlphaFold3 / AF3 structure prediction, folding a protein sequence, or validating a designed binder against its target. If the user only wants to look up an existing public model by UniProt accession (not a new prediction), use protforge-alphafold-db instead
deprecated: true
deprecated_since: 2026-10-07
superseded_by: [protforge-esmfold2, protforge-esmfold2-fast, protforge-opendde]
---

> # ⛔ DEPRECATED — do not use for new work
>
> **Superseded on 2026-10-07.** Prefer `protforge-esmfold2` (full, MSA-capable) or
> `protforge-esmfold2-fast` (single-sequence screening), and `protforge-opendde` for
> antibody-antigen co-folding.
>
> **Why it was retired:**
>
> 1. **Accuracy.** On FoldBench-AB (antibody-antigen DockQ pass rate),
>    independently re-run on identical inputs:
>    - OpenDDE **76.1%** · ESMFold2 **58.1%** · **AlphaFold3 47.9%**
>    - protein-protein: ESMFold2 76% vs AF3 73%
> 2. **Licence.** AF3 weights restrict commercial use. ESMFold2/ESMC weights
>    are MIT; OpenDDE is Apache-2.0 — both usable commercially.
> 3. **This container was mis-degraded.** `docker-compose.windows.yml` mounts
>    `D:/af3db_rw` at `/data/alphafold3_db`, but that directory is **0 GB
>    (empty)**. The real 398 GB database lives at
>    `<data-root>/models/af3_db` and in the `AF3Native` WSL distro at `/db`.
>    Consequence: AF3 here has always been forced into
>    `--norun_data_pipeline` single-sequence mode — the MSA path was never
>    actually active, so published AF3 numbers were never reproduced here.
> 4. **I/O.** The container bind-mounts from `E:` (mechanical disk) through
>    9p. Measured inside the container: 89 MB/s sequential write vs 470 MB/s
>    for native ext4 (Docker named volume). Long jobs stall in `D` state.
>
> **A working native install still exists** if you need AF3 specifically:
> the `AF3Native` WSL distro (`wsl.exe -d AF3Native`) has Python 3.12, both
> RTX 3080s, HMMER at `/hmmer/bin`, and the full 398 GB database at `/db` on
> native ext4. It is the same host `protforge-esmfold2` is installed into.
>
> **Do not delete this skill** — it is kept for reproducibility of past runs
> and for AF3-specific requests (custom MSA control, Par-seq, benchmarks that
> cite AF3 directly).

> Note: `${PLUGIN_DIR}` is the absolute install path of this plugin
> (`${PLUGIN_DIR}` for this installation). Resolve it from the plugin
> context and substitute before invoking the bash command below.

# AlphaFold 3 — structure prediction (DEPRECATED; see banner above)

Container `protforge-alphafold3` (GPU). Weights: `$PROTFORGE_HOME/models/alphafold3/af3.bin`;
genetic DBs: `$PROTFORGE_HOME/models/af3_db/` — **the latter is NOT actually mounted
into the container; the compose entry points at an empty `D:/af3db_rw`.**

## Check the public DB before predicting

AF3 jobs cost 5–40 min of GPU; a public DB lookup is free and takes seconds. When the
target is a natural protein with a UniProt accession, check the AlphaFold DB first via
`protforge-alphafold-db` (`afdb.py <ACC> --query-only`):

- A model already exists and its pLDDT/PAE fit the need → deliver the DB model, skip the
  GPU job.
- Run AF3 anyway when: no DB entry; the sequence is designed or mutated (even one point
  mutation invalidates the public model); the job involves complexes, ligands, RNA/DNA;
  or the user explicitly wants a fresh AF3 run (custom seeds, MSA control).

State the check outcome to the user either way ("DB already has AF-P69905-F1 v6" vs
"no public model — running AF3").

## Command (single-chain protein, one seed)

```bash
bash "${PLUGIN_DIR}/skills/protforge-alphafold3/scripts/af3.sh" "$job_name" "$sequence"
```

- `$sequence`: amino-acid sequence (single-letter, no spaces), or a FASTA/PDB path is
  NOT supported here — paste the raw sequence.
- `$job_name`: short lowercase job id, e.g. `her2_design_1`.

Runtime: MSA search (jackhmmer) + inference typically 5–40 min on 2×RTX 3080 for
<600 aa; the script streams progress.

## Reading the result

Output: `$PROTFORGE_HOME/data/outputs/<job>_af3/` containing `<job>_model.cif`,
`<job>_summary_confidences.json`, `<job>_confidences.json`.

Report: mean pLDDT / iPTM from `*_summary_confidences.json`, and where the CIF is.
For binder–target complexes, next step: interface scoring (PeSTo / ipSAE).

## Notes

- Multi-chain / ligand complexes: edit the generated JSON at
  `$PROTFORGE_HOME/data/inputs/<job>_af3.json` (add `sequences` entries: protein/rna/dna/
  ligand with `ccdCodes` or SMILES), then re-run with the same command.
- Single 20 GB GPU per AF3 job; the runner auto-picks the freer GPU.
