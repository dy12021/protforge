---
name: protforge-autodock-gpu
description: "AutoDock4 GPU docking with autodock-gpu (Docker container protforge-autodock-gpu) — requires a precomputed autogrid maps (.maps.fld) file Trigger: When the user asks to run AutoDock4 docking on GPU given a precomputed grid (maps.fld) and a ligand pdbqt — fast batch docking once grids exist"
---


> Note: `${PLUGIN_DIR}` is the absolute install path of this plugin
> (for this installation). Resolve it from the plugin
> context and substitute before invoking the bash command below.

# autodock-gpu — AutoDock4 on GPU

Runs `autodock_gpu_128wi` in the `protforge-autodock-gpu` container. A precomputed
AutoGrid map file (`.maps.fld`) is **required** — see Notes. Output lands in
`$PROTFORGE_HOME/data/outputs/<job_name>_autodock_gpu/`.

## Command

```bash
bash "${PLUGIN_DIR}/skills/protforge-autodock-gpu/scripts/protforge-autodock-gpu.sh" "$fld_file" "$ligand_pdbqt" "$job_name" "$num_poses"
```

- `$fld_file`: the `<name>.maps.fld` grid file (absolute host path or filename
  under inputs/). Its `.maps.*` siblings must sit in the same directory.
- `$ligand_pdbqt`: ligand in pdbqt format.
- `$num_poses`: docking runs; default 9 (the tool gets `--nrun 2*num_poses`).

The script prints `PROTFORGE_STATUS: OK` plus pose count and best energy if present.

## Reading the result

Output directory: `$PROTFORGE_HOME/data/outputs/<job_name>_autodock_gpu/`
- `result.pdbqt` — docked poses (`MODEL` blocks), `REMARK VINA RESULT`-style
  energies are not used here; see the `result.xml` for run metadata

Report to the user: number of poses returned and, if the pdbqt contains
energy remarks, the best binding energy (kcal/mol).

## Notes

- **Grid generation limitation**: `autogrid` / `autogrid4` is NOT in the image —
  only the `autodock_gpu_128wi` binary. Prepare grids outside the platform:
  use ADFR suite / AutoDockTools around the pocket center suggested by
  fpocket (protforge-fpocket) or p2rank (protforge-p2rank).
- Grid files can be large; keep each grid set in its own directory under
  `$PROTFORGE_HOME/data/inputs/` and pass the `.maps.fld` path.
