---
name: protforge-freesasa
description: Solvent accessible surface area (SASA) analysis and ADC conjugation site identification with FreeSASA (host Python, no Docker) — per-residue SASA and exposed Lys/Cys/Thr/Ser ranking Trigger: When the user asks for solvent accessible surface area per residue, exposed residues on a protein structure, or candidate conjugation sites for ADCs (antibody-drug conjugates) / surface lysines and cysteines
---

> Note: `${PLUGIN_DIR}` is the absolute install path of this plugin
> (`C:/Users/dy120/.minimax/plugins/protforge` for this installation). Resolve it from the plugin
> context and substitute before invoking the bash command below.

# freesasa — SASA & ADC conjugation site candidates

Runs FreeSASA on the **host** Python environment (`E:\protforge\venvs\protforge\python.exe`)
— no Docker involved. Input PDB comes from `$PROTFORGE_HOME/data/inputs`; output
lands in `$PROTFORGE_HOME/data/outputs/<job_name>_freesasa/`.

## Command

```bash
bash "${PLUGIN_DIR}/skills/protforge-freesasa/scripts/protforge-freesasa.sh" "$pdb_path" "$job_name"
```

`$pdb_path` may be an absolute host path or just a filename under inputs/.
The script prints `PROTFORGE_STATUS: OK` plus the top 5 conjugation candidates.

## Reading the result

Output directory: `$PROTFORGE_HOME/data/outputs/<job_name>_freesasa/`
- `sasa_per_residue.json` — every residue: chain, resname, resnum, total SASA
  (Å²)
- `adc_candidates.json` — Lys/Cys/Thr/Ser residues with SASA > 80 Å², sorted
  by exposure (top candidates first)

Report to the user: the top 5 coupling sites (residue, chain, SASA) with a
note that high solvent exposure is the primary criterion — for Cys also check
whether it is a free (reduced) cysteine vs a disulfide, and for Lys consider
proximity to the paratope/target-binding region before final selection.

## Notes

- Uses the NACCESS-style two-probe default of the freesasa package
  (Lee–Richards, probe radius 1.4 Å).
- Threshold 80 Å² is a heuristic for strong solvent exposure; adjust in the
  generated analysis if your scaffold demands stricter/looser cutoffs.
- mmCIF input is supported by freesasa, but keep inputs as PDB for consistency
  with the other ProtForge tools.
