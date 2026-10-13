---
name: protforge-alphafold-db
description: Query the public AlphaFold Protein Structure Database (Google DeepMind + EMBL-EBI, alphafold.ebi.ac.uk) by UniProt accession and download its pre-computed structure models (CIF/PDB + per-residue pLDDT + PAE). Trigger when the user gives a UniProt accession (e.g. P69905) or an AF-...-F1 entry id and asks to look up / fetch / download the public AlphaFold model, asks whether a prediction already exists in the AlphaFold database, or wants confidence scores for a known protein — including Chinese phrasing like "查 AlphaFold 数据库", "下载某蛋白的 AlphaFold 结构". Do NOT use for predicting a structure from a pasted sequence, or for complexes/ligands/RNA/DNA — the DB holds pre-computed monomers only; use protforge-alphafold3 for those.
---

> Note: `${PLUGIN_DIR}` is the absolute install path of this plugin
> (for this installation). Resolve it from the plugin
> context and substitute before invoking the command below.

# AlphaFold DB — query & download public predicted structures

Pure HTTP client; **no Docker container needed** (unlike the other protforge tools).
API: `GET https://alphafold.ebi.ac.uk/api/prediction/<ACCESSION>` → JSON array of
entries carrying `cifUrl` / `pdbUrl` / `plddtDocUrl` / `paeDocUrl` / `msaUrl` and
`globalMetricValue` (mean pLDDT). Free, no auth.

## Inputs to collect

- A UniProt accession (`P69905`) or AF DB entry id (`AF-P69905-F1`). If the user only
  has a gene/protein name, resolve it via UniProt first (pick a reviewed entry):
  `https://rest.uniprot.org/uniprotkb/search?query=gene_exact:<GENE>+AND+organism_id:<TAXID>&fields=accession,gene_names,protein_name,reviewed&format=json`
- Output directory — default: `$PROTFORGE_DATA/outputs/<ACC>_afdb` when `PROTFORGE_DATA` is set,
  otherwise `./afdb_outputs/<ACC>_afdb`.

## Procedure

Run the bundled script (query + summary + download in one step):

```bash
python "${PLUGIN_DIR}/skills/protforge-alphafold-db/scripts/afdb.py" P69905 --out "$PROTFORGE_DATA/outputs/P69905_afdb"
```

- `--files cif,pdb,pae,plddt,msa,bcif,pae-img,am` selects downloads (default `cif,pdb,pae,plddt`);
  `msa` (.a3m) can be tens of MB.
- `--query-only` prints the summary without downloading — use it when the user only asks
  whether a model exists or how confident it is; download only when they want the files.
- The response may contain several entries (long proteins split into fragments) — the
  script loops over all of them.

Report to the user: mean pLDDT with the standard bands (>90 very high, 70–90 confident,
50–70 low, <50 very low / often disordered), where the CIF is (`PROTFORGE_CIF:` marker), and the
entry page `https://alphafold.ebi.ac.uk/entry/<ACC>`.

## Output contract

- Summary lines per entry: entry id, gene/UniProt id, organism, length, mean pLDDT +
  pLDDT fractions, model version.
- Downloaded files named as served, e.g. `AF-P69905-F1-model_v6.cif`,
  `AF-P69905-F1-confidence_v6.json` (per-residue pLDDT),
  `AF-P69905-F1-predicted_aligned_error_v6.json` (PAE matrix). Prefer CIF over PDB —
  PDB is absent for very long proteins.
- Markers for chaining: `PROTFORGE_CIF: <path>` (first CIF), `PROTFORGE_STATUS: OK|FAIL <reason>`.

## Failure handling

- `FAIL ... Invalid identifier format` → accession malformed; re-check spelling.
- `FAIL ... no public AlphaFold DB entry` → valid accession but no pre-computed model
  (not in the DB's UniProt set, sequence too long, or a designed sequence). Do not
  retry — fall back to local prediction with `protforge-alphafold3`.
- Network error → retry once; if it persists, report the error instead of inventing
  file paths.
- Need a complex, ligand, RNA/DNA, or a brand-new sequence? Also `protforge-alphafold3`.

## Windows (win32) platform notes

- `python` (Anaconda base) is on PATH; the script is stdlib-only, no pip installs.
- PowerShell equivalent: `python "${PLUGIN_DIR}/skills/protforge-alphafold-db/scripts/afdb.py" P69905`
- Also works under Git Bash / WSL with the same `python` command.

## Examples

Input: "帮我下载人血红蛋白 α 链的 AlphaFold 结构（P69905）并看看可信度"
Run: `python "${PLUGIN_DIR}/skills/protforge-alphafold-db/scripts/afdb.py" P69905 --out <data-root>/data/outputs/P69905_afdb`
Output: mean pLDDT 98.06, 99.3% residues very-high confidence (model v6); CIF/PDB/confidence/PAE
saved under the output dir; entry page https://alphafold.ebi.ac.uk/entry/P69905.
