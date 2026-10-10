---
name: protforge-gnina
description: Deep-learning molecular docking with gnina (Docker container protforge-gnina) — CNN-scored pose prediction from a receptor PDB and a SMILES ligand Trigger: When the user asks to dock a small molecule (SMILES) into a protein binding site with deep learning scoring, or wants docked poses + CNN affinity/Score for a receptor/ligand pair
---

> Note: `${PLUGIN_DIR}` is the absolute install path of this plugin
> (`C:/Users/dy120/.minimax/plugins/protforge` for this installation). Resolve it from the plugin
> context and substitute before invoking the bash command below.

# gnina — deep learning docking

Runs `gnina` in the `protforge-gnina` container. The receptor PDB comes from
`$PROTFORGE_HOME/data/inputs`; the ligand is built on the host with RDKit
(`E:\protforge\venvs\protforge\python.exe`) as a 3D SDF — gnina reads SDF directly, no
pdbqt conversion needed. Output lands in
`$PROTFORGE_HOME/data/outputs/<job_name>_gnina/`.

## Command

```bash
bash "${PLUGIN_DIR}/skills/protforge-gnina/scripts/protforge-gnina.sh" "$receptor_pdb" "$smiles" "$job_name" "$center_x" "$center_y" "$center_z" "$box_size"
```

- `$receptor_pdb`: absolute host path or filename under inputs/.
- `$smiles`: ligand SMILES string (quote it).
- `$center_x/y/z`: docking box center. Default 0/0/0. **Recommended**: first run
  fpocket (protforge-fpocket) or p2rank (protforge-p2rank) to get a pocket center, then
  pass it here.
- `$box_size`: cubic box edge in Å, default 25.

The script prints `PROTFORGE_STATUS: OK` plus the best affinity / pose count.

## Reading the result

Output directory: `$PROTFORGE_HOME/data/outputs/<job_name>_gnina/`
- `docked.sdf` — up to 9 poses ranked by CNNscore, with SDF tags including
  `minimizedAffinity` (Vina affinity, kcal/mol) and `CNNscore` / `CNNaffinity`

Report to the user: the best (first) pose `minimizedAffinity` and its
`CNNscore`, the number of poses returned, and how the box center was chosen.

## Notes

- Runtime is roughly 1–5 minutes per ligand depending on GPU contention.
- Larger `--exhaustiveness` (8 here) and more poses trade speed for sampling;
  keep the defaults for quick screens.
- If the box center is wrong (e.g. 0/0/0 for a multi-chain structure), poses
  will land outside the intended pocket — always prefer a pocket-derived center.
