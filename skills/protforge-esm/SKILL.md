---
name: protforge-esm
description: "ESM-2 protein language model embeddings and pseudo-perplexity scoring (Docker container protforge-esm) — 650M parameter model, weights pre-cached Trigger: When the user asks for protein sequence embeddings, per-sequence quality/scoring (pseudo-perplexity), or featurization of protein sequences with ESM-2"
---


> Note: `${PLUGIN_DIR}` is the absolute install path of this plugin
> (for this installation). Resolve it from the plugin
> context and substitute before invoking the bash command below.

# esm — ESM-2 embeddings / pseudo-perplexity

Runs ESM-2 (`esm2_t33_650M_UR50D`) inside the `protforge-esm` container. Weights are
pre-cached in the container (`/root/.cache/torch/hub/checkpoints`), so no
network is needed. Sequences are passed directly as a comma-separated argument;
results land in `$PROTFORGE_HOME/data/outputs/<job_name>_esm/`.

## Command

```bash
bash "${PLUGIN_DIR}/skills/protforge-esm/scripts/protforge-esm.sh" "$job_name" "$sequences" "$mode"
```

- `$sequences`: comma-separated amino-acid sequences (no FASTA headers), e.g.
  `"MKTVRQGSG,MKTVRQ"`. Sequences longer than 1022 residues are truncated.
- `$mode`: `embed` (default) or `score`.
  - `embed`: mean-pooled last-layer representation per sequence.
  - `score`: pseudo-perplexity approximation from the teacher-forced
    log-probability of each wild-type residue.

The script prints `PROTFORGE_STATUS: OK` plus sequence count and embedding dim.

## Reading the result

Output directory: `$PROTFORGE_HOME/data/outputs/<job_name>_esm/`
- `mean_embeddings.npz` — array `emb` of shape (n_seq, 1280) (embed mode)
- `results.json` — per-sequence metadata; in score mode each entry carries
  `pseudo_perplexity` (lower = more plausible sequence)

Report to the user: number of sequences processed, embedding dimension (1280),
and in score mode the sequences ranked by pseudo-perplexity.

## Notes

- First load of the 650M model takes tens of seconds on CPU; batch all
  sequences you need in one call.
- This is a light convenience wrapper — for masked-marginal exact
  pseudo-likelihoods or per-residue logits, extend the generated script in
  `$PROTFORGE_HOME/data/tmp/<job>_esm.py`.
