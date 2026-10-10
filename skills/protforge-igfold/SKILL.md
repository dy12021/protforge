---
name: protforge-igfold
description: Predict antibody / nanobody 3D structures from sequences with IgFold (Docker container protforge-igfold) Trigger: When the user asks to predict/model an antibody, nanobody (VHH), Fab, or Fv structure from heavy/light chain sequences, or to assess antibody model confidence
---

> Note: `${PLUGIN_DIR}` is the absolute install path of this plugin
> (`C:/Users/dy120/.minimax/plugins/protforge` for this installation). Resolve it from the plugin
> context and substitute before invoking the bash command below.

# IgFold — antibody structure prediction

Runs IgFold in the `protforge-igfold` container. Sequences are passed directly (no input
file needed); output lands in `$PROTFORGE_HOME/data/outputs/<job>_igfold/`.

## Command

```bash
bash "${PLUGIN_DIR}/skills/protforge-igfold/scripts/igfold.sh" "$job_name" "$heavy_seq" "$light_seq" "$do_refine"
```

- `$job_name` — job/output folder name (required)
- `$heavy_seq` — heavy chain (or nanobody VHH) amino-acid sequence, one letter code (required)
- `$light_seq` — light chain sequence; empty for nanobodies (default: empty)
- `$do_refine` — run refinement stage, default `false`

The script prints `PROTFORGE_STATUS: OK` on success plus mean pLDDT / residue count lines.

## Reading the result

Output directory: `$PROTFORGE_HOME/data/outputs/<job>_igfold/`
- `pred.pdb` — predicted structure (H and/or L chains)
- `result.json` — `mean_prmsd`, `mean_plddt` (pseudo-pLDDT = 100 − 20×per-residue
  RMSD, clamped to [0,100]), `num_residues`, `do_refine`

Report to the user: `mean_plddt` and modeled residue count. Rule of thumb:
pLDDT > 90 excellent, 80–90 good, < 70 treat with caution. For nanobodies pass
only `$heavy_seq`.

## Notes

- Input should be the variable (Fv/VHH) domain or full chain; IgFold focuses on
  antibody folds. Non-antibody proteins belong to protforge-alphafold3 / protforge-esm.
- `do_renum` is disabled (output keeps input numbering); `do_refine=true` adds a
  refinement stage and takes longer.
