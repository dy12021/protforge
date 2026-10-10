---
name: protforge-gromacs
description: Protein molecular dynamics setup and short simulation with GROMACS (Docker container protforge-gromacs) — pdb2gmx, solvation, ions, minimization, NVT/NPT equilibration, production MD Trigger: When the user asks to run a (quick) molecular dynamics simulation of a protein, prepare a solvated+neutralized system, or produce equilibrated gro/xtc/tpr files for a protein structure
---

> Note: `${PLUGIN_DIR}` is the absolute install path of this plugin
> (`C:/Users/dy120/.minimax/plugins/protforge` for this installation). Resolve it from the plugin
> context and substitute before invoking the bash command below.

# gromacs — protein MD (single protein in water)

Runs a standard GROMACS pipeline in the `protforge-gromacs` container:
`pdb2gmx (charmm27/tip3p) → editconf → solvate → genion (neutralize) →
energy minimization → NVT → NPT → production MD`.

Input PDB comes from `$PROTFORGE_HOME/data/inputs`; everything lands in
`$PROTFORGE_HOME/data/outputs/<job_name>_gromacs/`.

## Command

```bash
bash "${PLUGIN_DIR}/skills/protforge-gromacs/scripts/protforge-gromacs.sh" "$pdb_path" "$job_name" "$steps"
```

- `$pdb_path`: absolute host path or filename under inputs/. Must be a
  single protein chain/system that pdb2gmx accepts (clean PDB, standard
  residues; missing loops/heteroatoms may cause pdb2gmx to fail).
- `$steps`: MD steps for nvt/npt/md, default 5000. Use ~100 for smoke tests.

The script prints `PROTFORGE_STATUS: OK` plus final files and the minimized
`Potential` energy.

## Reading the result

Output directory: `$PROTFORGE_HOME/data/outputs/<job_name>_gromacs/` (the script also
prints it as `PROTFORGE_OUTPUT_DIR`).
- `processed.gro`, `ionized.gro` — parameterized, solvated, neutralized system
- `em.gro/.log`, `nvt.gro/.cpt/.xtc`, `npt.*`, `md.tpr`, `md.xtc`, `md.gro` —
  minimization, equilibration and production outputs
- `topol.top`, `*.mdp` — topology and run parameters used

Report to the user: final `md.gro` / `md.tpr` / `md.xtc` paths, the last
`Potential` energy from `em.log`, and system size (atom count from the log).
For anything beyond a quick equilibration, continue in the container with
longer mdp files.

## Notes

- **Protein-only scope**. Ligand parametrization (GAFF via acpype) is NOT
  installed — protein-ligand MD is on the roadmap.
- Force field charmm27 and spc216 water ship with gromacs-data in the image;
  MDP templates live in this skill's `references/` directory and are copied
  (with `nsteps` replaced by `$steps`) into the output directory.
- `--maxwarn 1` is used on the ions grompp because solvated systems from
  tip3p occasionally raise a benign warning; inspect warnings if the run fails.
