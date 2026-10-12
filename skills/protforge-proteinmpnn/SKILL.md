---
name: protforge-proteinmpnn
description: Design protein sequences for a given backbone structure with ProteinMPNN (Docker container protforge-proteinmpnn) Trigger: When the user asks to design sequences for a protein structure, fix/salvage a backbone with sequence design, or generate variant sequences for a PDB (fixed-backbone sequence design)
---

> Note: `${PLUGIN_DIR}` is the absolute install path of this plugin
> (`${PLUGIN_DIR}` for this installation). Resolve it from the plugin
> context and substitute before invoking the bash command below.

# ProteinMPNN — fixed-backbone sequence design

Runs ProteinMPNN in the `protforge-proteinmpnn` container. Input structure comes from
`$PROTFORGE_HOME/data/inputs`, output lands in `$PROTFORGE_HOME/data/outputs/<job>_proteinmpnn/`.

## Command

```bash
bash "${PLUGIN_DIR}/skills/protforge-proteinmpnn/scripts/proteinmpnn.sh" "$pdb_path" "$chains" "$num_sequences" "$sampling_temp" "$job_name"
```

- `$pdb_path` — absolute host path or filename under inputs/ (required)
- `$chains` — chain(s) to design, comma-separated, default `A`
- `$num_sequences` — sequences per target, default `8`
- `$sampling_temp` — sampling temperature, default `0.1` (lower = closer to wild-type-like)
- `$job_name` — output folder name, default: PDB stem

The script prints `PROTFORGE_STATUS: OK` on success plus `PROTFORGE_SEQUENCES` (count).

## Reading the result

Output directory: `$PROTFORGE_HOME/data/outputs/<job>_proteinmpnn/`
- `seqs/<stem>.fa` — designed sequences as FASTA (header contains score, seq recovery, etc.)
- `scores/` — per-sequence score files (if enabled)

Report to the user: number of designed sequences, the best-scoring sequence and its
sequence recovery. Lower ProteinMPNN score = better. For ligand-aware design use
LigandMPNN; for interface-only design consider restricting `$chains` to the target.

## Notes

- Backbone atoms are fixed; only side chains / sequence are redesigned.
- Designs are unrelaxed — run a structure predictor (protforge-alphafold3 / protforge-esm) on
  top designs to validate foldability before ordering.
