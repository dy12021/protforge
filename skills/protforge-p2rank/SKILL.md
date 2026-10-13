---
name: protforge-p2rank
description: "Predict and rank protein binding pockets with P2Rank machine learning (Docker container protforge-p2rank) Trigger: When the user asks for ML-based binding pocket prediction, ligandable site ranking, or a cross-check of fpocket pocket detection on a protein structure (PDB)"
---


> Note: `${PLUGIN_DIR}` is the absolute install path of this plugin
> (for this installation). Resolve it from the plugin
> context and substitute before invoking the bash command below.

# p2rank — ML binding pocket prediction

Runs P2Rank `prank predict` in the `protforge-p2rank` container. Input structure comes
from `$PROTFORGE_HOME/data/inputs`, output lands in `$PROTFORGE_HOME/data/outputs/<job_name>_p2rank/`.

## Command

```bash
bash "${PLUGIN_DIR}/skills/protforge-p2rank/scripts/protforge-p2rank.sh" "$pdb_path" "$job_name"
```

`$pdb_path` may be an absolute host path or just a filename under inputs/.
The script prints `PROTFORGE_STATUS: OK` on success plus the top pocket lines.

Note: the very first run downloads/loads the Java ML model and can take ~6
minutes; subsequent runs are fast (seconds). Do not interrupt the first run.

## Reading the result

Output directory: `$PROTFORGE_HOME/data/outputs/<job_name>_p2rank/`
- `<stem>.pdb_predictions.csv` — one row per predicted pocket, ranked by
  probability/score (column names are `probability` / `prediction` /
  `rank` depending on p2rank version)
- `<stem>.pdb_residues.csv` — per-residue pocket membership for each prediction

Report to the user: the top 3 pockets with their rank and score
(probability), and which residues define pocket 1. Cross-check with fpocket
(protforge-fpocket skill) when druggability/volume numbers are also needed.

## Notes

- Pocket centers (pocket centroid columns in the CSV) can feed docking box
  centers for gnina (protforge-gnina) or vina-gpu (protforge-vina-gpu).
- Input must be PDB format (not mmCIF) for this container build.
