---
name: protforge-discotope3
description: Predict B-cell epitopes on protein structures with Discotope3 (Docker container protforge-discotope3) Trigger: When the user asks to predict B-cell epitopes, antibody epitope residues, antigenic surface regions, or vaccine/immunogenicity-relevant sites on a protein structure
---

> Note: `${PLUGIN_DIR}` is the absolute install path of this plugin
> (`${PLUGIN_DIR}` for this installation). Resolve it from the plugin
> context and substitute before invoking the bash command below.

# Discotope3 — B-cell epitope prediction

Runs Discotope3 in the `protforge-discotope3` container. Input structure from
`$PROTFORGE_HOME/data/inputs`, output in `$PROTFORGE_HOME/data/outputs/<job>_discotope3/`.

## Command

```bash
bash "${PLUGIN_DIR}/skills/protforge-discotope3/scripts/discotope3.sh" "$pdb_path" "$job_name" "$threshold" "$multichain"
```

- `$pdb_path` — absolute host path or filename under inputs/ (required)
- `$job_name` — output folder name, default: PDB stem
- `$threshold` — calibrated-score epitope threshold, default `0.5`
  (low 0.40 / moderate 0.90 / higher 1.50)
- `$multichain` — `true` to score the whole complex (default `false`, single chain)

The script prints `PROTFORGE_STATUS: OK` on success, the output file list, and
`PROTFORGE_EPI_RESIDUES` (epitope residue count from the epitope CSV).

## Reading the result

Output directory: `$PROTFORGE_HOME/data/outputs/<job>_discotope3/`
- `<input_stem>/<chain>_discotope3.csv` — one CSV per chain, per-residue:
  `DiscoTope-3.0_score`, `calibrated_score`, `epitope` (True/False at threshold),
  `rsa`, `pLDDTs`
- `log.txt` — pipeline log

`PROTFORGE_EPI_RESIDUES` counts rows with `epitope == True` across all chain CSVs.
Report to the user: number of predicted epitope residues, the threshold used, and
the top-scoring residues. Cross-check with PeSTo (protforge-pesto) for the
protein-interface context of the predicted epitope.

## Notes

- Designed for solved structures (`--struc_type solved`); AlphaFold inputs are
  supported by the tool but this skill defaults to solved.
- GPU is used when available; long antigens fall back to CPU embedding.
