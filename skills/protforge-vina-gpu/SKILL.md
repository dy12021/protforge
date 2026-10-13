---
name: protforge-vina-gpu
description: "Fast GPU molecular docking with Vina-GPU (Docker container protforge-vina-gpu) — pdbqt-based docking in a user-defined box Trigger: When the user asks to dock a ligand (pdbqt) into a receptor (pdbqt) quickly on GPU with AutoDock Vina scoring, given a binding box center"
---


> Note: `${PLUGIN_DIR}` is the absolute install path of this plugin
> (for this installation). Resolve it from the plugin
> context and substitute before invoking the bash command below.

# vina-gpu — fast GPU docking

Runs `vina_gpu` in the `protforge-vina-gpu` container. Both receptor and ligand must
be in **pdbqt** format. Output lands in
`$PROTFORGE_HOME/data/outputs/<job_name>_vina_gpu/`.

## Command

```bash
bash "${PLUGIN_DIR}/skills/protforge-vina-gpu/scripts/protforge-vina-gpu.sh" "$receptor" "$ligand" "$job_name" "$center_x" "$center_y" "$center_z"
```

- `$receptor` / `$ligand`: absolute host paths or filenames under inputs/,
  in `.pdbqt` (recommended).
- `$center_x/y/z`: docking box center (required — get it from fpocket
  protforge-fpocket or p2rank protforge-p2rank first).

The script prints `PROTFORGE_STATUS: OK` plus the pose count.

## Reading the result

Output directory: `$PROTFORGE_HOME/data/outputs/<job_name>_vina_gpu/`
- `docked.pdbqt` — up to 9 poses, one `MODEL` block each, with Vina affinity
  in the `REMARK VINA RESULT` line of each model

Report to the user: number of poses (`MODEL` count) and the best (first)
`REMARK VINA RESULT` affinity (kcal/mol).

## Notes

- **pdbqt preparation limitation**: the container has no `prepare_receptor` /
  `prepare_ligand` (no ADFR/AutoDockTools). Provide pdbqt files prepared
  externally, e.g. with ADFR suite (`prepare_receptor -r protein.pdb`) or
  Meeko (`mk_prepare_receptor.py`). If a `.pdb` is passed instead, the script
  copies it to the output directory as a placeholder and stops with a clear
  message — conversion must happen outside this skill.
- Box size is fixed at 25 Å per axis (fast-screening default); adjust in the
  script if a bigger box is needed.
