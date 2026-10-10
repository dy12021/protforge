---
name: protforge-af3-msa
description: Generate .a3m multiple-sequence alignments from the AlphaFold 3 genetic database using MMseqs2, for feeding into ESMFold2 (MSA mode) and OpenDDE (pairedMsaPath/unpairedMsaPath). Runs in the AF3Native WSL distro, searching /db in place. Trigger when a folding job needs MSA input, when MSA-conditioned accuracy is requested, or when preparing the same alignments for both ESMFold2 and OpenDDE. Use before protforge-esmfold2 full-variant jobs; not needed for protforge-esmfold2-fast, which is single-sequence by design.
---

# AF3 database → .a3m MSAs

Host: **AF3Native WSL** (`wsl.exe -d AF3Native`). MMseqs2 at
`/esmfold2/bin/mmseqs/bin/mmseqs`. Database `/db` (398 GB, native ext4).

## Why MMseqs2 and not jackhmmer

HMMER would rescan the whole database per query. MMseqs2 builds a reusable index
once, then a search is seconds. `/hmmer/bin/jackhmmer` exists but is only usable
against small targets.

## Database choice is a space decision

Index size ≈ database size. `/db` holds:

| File | Size | Index | Fits D: (~91 GB free)? |
|---|---|---|---|
| `bfd-first_non_consensus_sequences.fasta` | 18 GB | ~25 GB | ✅ **use this** |
| `uniref90_2022_05.fa` | 72 GB | ~90 GB | ❌ would fill the disk |
| `mgy_clusters_2022_05.fasta` | 120 GB | — | ❌ |
| `uniprot_all_2021_04.fa` | 102 GB | — | ❌ |

**bfd is also AF3's own curated primary database**, so MSAs generated from it stay
consistent with what AF3 itself would have searched.

## Command

Write the query FASTA somewhere WSL can read, then:

```bash
bash /mnt/e/protforge/protforge-upgrade/02-newtools/gen_a3m.sh bfd /esmfold2/msa/query.fasta /esmfold2/msa/out 2048
```

First run builds the bfd index (~25 GB, minutes). Later runs reuse it.

## MMseqs2 traps found the hard way

These all fail **silently-ish**: mmseqs prints its usage block and exits 1, or
appears to run and produces nothing.

| Mistake | Consequence | Correct |
|---|---|---|
| `convert2a3m` | `Invalid Command` — it does not exist | `result2msa … --msa-format-mode 2` then `convert2fasta` |
| `--max-seqs-mode` on `easy-search` | rejected, nothing runs | it belongs to `result2msa`; drop it from `easy-search` |
| `createindex db out index` (3 args) | usage dump | **2 args only**: `createindex <seqDB> <tmpDir>`; index lands in tmpDir |
| `--shuffle` / `--split-memory-limit` on `createindex` | usage dump | bare `createindex`; those flags belong to `easy-search` |
| `--index-subset` on `easy-search` | usage dump | it belongs to `search`, not `easy-search` |
| `--format-output "query,target,…"` with a `.tsv` path | usage dump | `easy-search` writes a **result DB**, not text |
| `createindex /db/bfd…fasta idx` (raw FASTA) | `Database … needs header information`, rc=1 | **`createindex` needs a mmseqs DB**: run `createdb <fasta> <db>` first, then `createindex <db> <tmpDir>` |

A bare `createindex` that "worked" on a small slice may be a false positive: it
only succeeded there because the input was already `createdb` output.

## Space: the index is not free

`createdb` writes a DB roughly the size of the FASTA (~18 GB for bfd) and
`createindex` ~1.4× that — **~43 GB total**, on top of ESMFold2's ~43 GB, against
~91 GB free on D:. That is ~95% of the drive.

`build_bfd_index.sh` therefore **checks free space and exits 2 rather than
starting** when under ~45 GB. Run it only after ESMFold2 is installed and
verified. `gen_a3m.sh` can instead search the FASTA directly, which works but
rescans the whole database per query.

Working core sequence:

```bash
mmseqs createdb query.fasta qDB
mmseqs createindex targetDB idxTmp              # 2 positional args, no flags
mmseqs easy-search qDB targetDB resultDB tmp -e 10000 --max-seqs 2048 -s 7.5 --threads 16
mmseqs result2msa qDB targetDB resultDB msaDB --msa-format-mode 2
mmseqs convert2fasta msaDB out.a3m
```

## Do not validate on a head slice

A truncated slice of `bfd` **cannot validate this pipeline**. Measured: the
rat EPO motif `TKVNFYAWKR` has **0 exact matches in the first 400,000 bfd
sequences**, so a head-slice search returns zero hits and looks like a broken
pipeline when it is working correctly. bfd is shuffled; homologs are scattered
throughout.

Validate either against the **full** database, or against a deliberately
shuffled random sample large enough to contain real homologs — never `head -N`.
A zero-hit result is only meaningful once you know the search space actually
contains the query.

## Wiring the output

ESMFold2:

```python
from esm.utils.msa.msa import MSA
ProteinInput(id="A", sequence=seq, msa=MSA.from_a3m(path, max_sequences=2048))
```

OpenDDE: put the path in the job JSON as `pairedMsaPath` / `unpairedMsaPath`.

## a3m pitfalls

- `MSA.from_a3m(remove_insertions=True)` **asserts all rows are the same length**.
  MMseqs2/ColabFold a3m often carry trailing NUL bytes and an off-by-one row
  count. Clean with `tr -d '\000'` and force row 0 to the exact query sequence;
  or build rows yourself with `MSA.from_sequences`.
- MSAs are per-chain. Every chain of a complex needs its own file.
- Antibody CDR regions are somatically recombined and have no deep alignment.
  Expect shallow MSAs there — this is precisely why ESMFold2-Fast exists and why
  single-sequence Ab-Ag results are nearly as good.

## Failure handling

- Disk full during `createindex` → you picked the wrong DB; switch to `bfd`.
- `easy-search` finds nothing → sequence too short / no homologs; fall back to
  single-sequence mode.
- Index corrupt after an interrupted run → delete `$MMDBS/${DB}_index*` and rerun.

## Windows (win32) platform notes

- Invoke as `wsl.exe -d AF3Native -- bash <script> <args>`; do not inline the
  FASTA path into a quoted `python -c`.
- Host `E:\protforge\...` maps to `/mnt/e/protforge/...`; `/db` and `/esmfold2` are
  WSL-internal with no host path.
- A `wsl.exe` timeout does not stop the WSL-side job, but can kill it. For the
  long index build, launch detached inside WSL.
