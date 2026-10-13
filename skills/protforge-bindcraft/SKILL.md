---
name: protforge-bindcraft
description: "Launch end-to-end protein binder design with BindCraft (Docker container protforge-bindcraft, PyRosetta-free mode) Trigger: When the user asks to design a binder/de novo protein that binds a target, design binders against a target structure with specified hotspots, or run the BindCraft binder-design pipeline"
---


> Note: `${PLUGIN_DIR}` is the absolute install path of this plugin
> (for this installation). Resolve it from the plugin
> context and substitute before invoking the bash command below.

# BindCraft — end-to-end binder design

Launches the BindCraft pipeline in the `protforge-bindcraft` container. The target PDB must
live under `$PROTFORGE_HOME/data` (mounted as `/data/protforge` in the container). Output lands in
`$PROTFORGE_HOME/data/outputs/<job>_bindcraft/`.

## Command

```bash
bash "${PLUGIN_DIR}/skills/protforge-bindcraft/scripts/bindcraft.sh" "$target_pdb" "$target_chains" "$hotspots" "$job_name" "$num_final_designs"
```

- `$target_pdb` — absolute host path or filename under inputs/ (required)
- `$target_chains` — target chain(s), e.g. `A` or `A,B` (required)
- `$hotspots` — comma-separated target residue numbers to bias binding, e.g. `56,57` (required)
- `$job_name` — job/output folder name (required)
- `$num_final_designs` — number of final binders to accept, default `5`

The script validates inputs, writes `inputs/settings_target/<job>.json` (all paths
translated to container paths), and **launches the design detached** — it returns
immediately with `PROTFORGE_STATUS: OK` and a run.log path. Design takes hours.

## Reading the result

Output directory: `$PROTFORGE_HOME/data/outputs/<job>_bindcraft/`
- `run.log` — live pipeline log; monitor with `tail -f`
- `Trajectory/` — hallucinated backbones (`.pdb`) plus `Trajectory/Relaxed/`
- `MPNN/` — ProteinMPNN-designed sequences per accepted trajectory
- `*.csv` — `trajectory_stats.csv`, `mpnn_design_stats.csv`, `final_design_stats.csv`
  with per-design filters/scores; `final_design_stats.csv` lists accepted binders

Report to the user: launch confirmation, log path, and (once finished) accepted
designs from `final_design_stats.csv` with their AF2 confidence metrics
(iptm / pae_interaction).

## Notes

- ⚠️ **PyRosetta is NOT installed** in this container (stub mode). Rosetta relaxation
  and Rosetta interface-energy filters are skipped; results are filtered by
  AlphaFold2 confidence metrics only. Install PyRosetta to restore the full
  relaxation/filtering pipeline.
- ⚠️ Known issue in the current image: `bindcraft.py` calls `pr.init(...)`
  unconditionally at startup, so the pipeline crashes immediately in stub mode
  (NameError: pr) until that call is guarded by `PYROSETTA_AVAILABLE` from
  `functions/pyrosetta_utils.py`. The launch script detects this and reports FAIL.
- `$hotspots` uses bare residue numbers as in the reference PDL1 example.
- The pipeline runs until `$num_final_designs` binders pass filters or the
  trajectory budget is exhausted; check `run.log` and the failure CSV for progress.
