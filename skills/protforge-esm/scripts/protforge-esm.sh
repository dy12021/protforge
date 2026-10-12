#!/usr/bin/env bash
# esm runner: ESM-2 embeddings / pseudo-perplexity for protein sequences.
# Model weights are pre-cached in the container (no network needed).
set -euo pipefail
# Locate the shared helper. A plugin install resolves ../../../scripts/, but
# a standalone skills install (~/.minimax/skills/<skill>/scripts) has no such
# parent, so fall back to the installed plugin tree before giving up.
__pf_lib=""
for __pf_c in "$(dirname "$0")/../../../scripts/_common.sh" \
              "$HOME/.minimax/plugins/protforge/scripts/_common.sh"; do
  if [ -f "$__pf_c" ]; then __pf_lib="$__pf_c"; break; fi
done
if [ -z "$__pf_lib" ]; then
  echo "PROTFORGE_STATUS: FAIL cannot locate scripts/_common.sh" >&2
  exit 1
fi
source "$__pf_lib"
unset __pf_lib __pf_c

JOB="${1:?usage: protforge-esm.sh <job_name> <seq1,seq2,...> [embed|score]}"
SEQS="${2:?missing sequences (comma-separated)}"
MODE="${3:-embed}"
case "$MODE" in embed|score) ;; *) protforge_fail "mode must be embed|score, got: $MODE"; exit 1;; esac

OUT_HOST="$PROTFORGE_DATA/outputs/${JOB}_esm"
mkdir -p "$OUT_HOST"
C_OUT="$(protforge_container_path "$OUT_HOST")"
PY_HOST="$PROTFORGE_DATA/tmp/${JOB}_esm.py"
C_PY="$PROTFORGE_MOUNT/tmp/${JOB}_esm.py"
mkdir -p "$PROTFORGE_DATA/tmp"

# Write the in-container inference script (kept under data/tmp for inspection).
cat > "$PY_HOST" <<'PY'
import sys, json
import numpy as np
import torch
import esm

seqs_csv, mode, out_dir = sys.argv[1], sys.argv[2], sys.argv[3]
seqs = seqs_csv.split(",")
assert all(s and set(s) <= set("ACDEFGHIKLMNPQRSTVWY") for s in seqs), \
    "sequences must be non-empty and contain only standard amino acids"

model, alphabet = esm.pretrained.esm2_t33_650M_UR50D()
model = model.eval().to("cuda" if torch.cuda.is_available() else "cpu")
batch_converter = alphabet.get_batch_converter()
MAXLEN = 1022
data = [(f"seq{i}", s[:MAXLEN]) for i, s in enumerate(seqs)]
_, _, toks = batch_converter(data)
toks = toks.to(next(model.parameters()).device)

with torch.no_grad():
    out = model(toks, repr_layers=[33], return_contacts=False)
reprs = out["representations"][33]           # (B, L+2, 1280)
mask = (toks != alphabet.padding_idx).unsqueeze(-1).float()
mask[:, 0] = 0                                # drop BOS
mask[torch.arange(len(seqs)), [len(s)+1 for _, s in data]] = 0  # drop EOS
mean_emb = (reprs * mask).sum(1) / mask.sum(1)
np.savez(f"{out_dir}/mean_embeddings.npz", emb=mean_emb.cpu().numpy())

results = [{"id": f"seq{i}", "sequence": s[:MAXLEN], "length": len(s[:MAXLEN])}
           for i, s in enumerate(seqs)]
if mode == "score":
    logits = out["logits"]                    # (B, L+2, vocab)
    logp = torch.log_softmax(logits.float(), dim=-1)
    for i, (name, s) in enumerate(data):
        tgt = toks[i, 1:len(s)+1]             # positions 1..L predict residues
        lp = logp[i, :len(s)].gather(-1, tgt.unsqueeze(-1)).squeeze(-1)
        results[i]["pseudo_perplexity"] = float(torch.exp(-lp.mean()))
with open(f"{out_dir}/results.json", "w") as fh:
    json.dump(results, fh, indent=2)
print("PROTFORGE_SEQUENCES: %d" % len(seqs))
print("PROTFORGE_EMB_DIM: %d" % mean_emb.shape[1])
PY

protforge_exec protforge-esm python3 "$C_PY" "$SEQS" "$MODE" "$C_OUT"

if [ -f "$OUT_HOST/results.json" ]; then
  echo "PROTFORGE_OUTPUT_DIR: $OUT_HOST"
  echo "PROTFORGE_OUTPUT_NPZ: $OUT_HOST/mean_embeddings.npz"
  echo "PROTFORGE_OUTPUT_JSON: $OUT_HOST/results.json"
  protforge_ok
else
  protforge_fail "esm produced no results.json"
  exit 1
fi
