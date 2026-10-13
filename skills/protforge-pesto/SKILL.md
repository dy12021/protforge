---
name: protforge-pesto
description: "Predict protein-protein interface residues with PeSTo (Docker container protforge-proteinmpnn) Trigger: When the user asks to predict protein-protein interaction interfaces, binding surface residues, PPI hotspots, or interaction sites on a protein structure"
---


> Note: `${PLUGIN_DIR}` is the absolute install path of this plugin
> (for this installation). Resolve it from the plugin
> context and substitute before invoking the bash command below.

# PeSTo — protein-protein interface prediction

Runs PeSTo (`predict_cli.py`) in the `protforge-proteinmpnn` container (both tools share
this container; PeSTo lives in `/app/pesto`). Input from `$PROTFORGE_HOME/data/inputs`,
output in `$PROTFORGE_HOME/data/outputs/<job>_pesto/`.

## Command

```bash
bash "${PLUGIN_DIR}/skills/protforge-pesto/scripts/pesto.sh" "$pdb_path" "$threshold" "$chain_id" "$job_name"
```

- `$pdb_path` — absolute host path or filename under inputs/ (required)
- `$threshold` — probability cutoff for hotspot calling, default `0.5`
- `$chain_id` — optional; restrict prediction to this chain (extracted with gemmi)
- `$job_name` — output folder name, default: PDB stem

The script prints `PROTFORGE_STATUS: OK` on success and echoes the full result JSON
between `PROTFORGE_RESULT_JSON_BEGIN/END` markers.

## Reading the result

`result.json` structure:
- `scores` — `{residue_id: probability}` per-residue interface propensity
- `hotspots` — residue list above threshold
- `num_hotspots`, `max_score`, `threshold` — summary fields

Report to the user: `num_hotspots`, `max_score`, and the top-5 residues by score.
Cross-check with fpocket (protforge-fpocket) if the interface overlaps a pocket, or
Discotope3 (protforge-discotope3) for antibody-relevant surfaces.

## Notes

- Without `$chain_id` the whole structure is scored (including crystal-packing
  partners if present in the PDB). Pass the chain of interest for cleaner results.
- PeSTo predicts *protein* interfaces only — not small-molecule or nucleic-acid
  binding sites.
