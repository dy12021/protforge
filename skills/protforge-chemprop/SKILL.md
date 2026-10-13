---
name: protforge-chemprop
description: "ADMET property prediction with chemprop (Docker container protforge-chemprop) — predict properties (default ESOL solubility) from SMILES using trained models in the ProtForge model library Trigger: When the user asks to predict ADMET properties (solubility, lipophilicity, toxicity, etc.) from SMILES strings using a trained chemprop model"
---


> Note: `${PLUGIN_DIR}` is the absolute install path of this plugin
> (for this installation). Resolve it from the plugin
> context and substitute before invoking the bash command below.

# chemprop — ADMET property prediction

Runs `chemprop predict` in the `protforge-chemprop` container against a trained model
from the ProtForge model library. Input SMILES are written to a CSV for you; results
land in `$PROTFORGE_HOME/data/outputs/<job_name>_chemprop/`.

## Command

```bash
bash "${PLUGIN_DIR}/skills/protforge-chemprop/scripts/protforge-chemprop.sh" "$job_name" "$smiles" "$model"
```

- `$smiles`: comma-separated SMILES, e.g. `"CCO,c1ccccc1"`.
- `$model`: container-visible model path. Default:
  `/data/protforge/models/admet/models/esol/model_0/best.pt` (ESOL aqueous
  solubility, log molar). Pass any other trained endpoint checkpoint.

The script prints `PROTFORGE_STATUS: OK` plus the prediction table.

## Reading the result

Output directory: `$PROTFORGE_HOME/data/outputs/<job_name>_chemprop/`
- `preds.csv` — input SMILES + prediction column(s)
- `<job>_smiles.csv` — the generated input file (kept in inputs/)

Report to the user: one row per SMILES with its predicted value and a short
interpretation (e.g. ESOL = log solubility in mol/L; higher = more soluble).

## Notes

- Model library lives at `<models-root>\admet\models\<endpoint>\`; only ESOL
  is trained so far. Train new endpoints in-container per
  `<models-root>\admet\README.md` (MoleculeNet endpoints: FreeSolv,
  Lipophilicity, BACE, BBBP, ClinTox, MUV, SIDER, Tox21, ToxCast, PCBA, HIV).
- Prediction runs on CPU by design (`--accelerator cpu`) and is fast.
- Custom models trained elsewhere must be chemprop v2 checkpoints and be placed
  under `$PROTFORGE_HOME/models/` (mounted read-only into the container).
