---
name: protforge-af3-msa
description: Generate .a3m multiple-sequence alignments from the AlphaFold 3 genetic database at /db, for feeding into OpenDDE (unpairedMsaPath) and ESMFold2 full (msa map). Runs in the AF3Native WSL distro and reads /db in place, costing no extra disk. Trigger when a folding job needs MSA input, when MSA-conditioned accuracy is requested, or when preparing the same alignments for both OpenDDE and ESMFold2. Use before protforge-esmfold2 full-variant jobs; not needed for protforge-esmfold2-fast, which is single-sequence by design.
---

# AF3 database → .a3m MSAs (shared by OpenDDE + ESMFold2)

Host: **AF3Native WSL** (`wsl.exe -d AF3Native`). One cache, two consumers.

| Piece | Path |
|---|---|
| genetic databases | `/db` (AF3 v3.0 archives, bind-mounted from `<models-root>\af3_db`) |
| jackhmmer | `/hmmer/bin/jackhmmer` (AF3's own build, with the `--seq_limit` patch) |
| AF3 python package | `/app/alphafold/src` — usable only from `/alphafold3_venv/bin/python` |
| shared a3m cache | `/msashared/cache/<dbset>/<hash>.a3m` |
| scripts | `<tools-dir>/` |

## What is actually in /db

Verified 2026-10-11 with `ls -la /db` + `df`. The "small" label in AF3's flag
names is relative to uniref90, not to disk.

| File | Size | Filesystem | Read speed | Protein MSA? |
|---|---|---|---|---|
| `bfd-first_non_consensus_sequences.fasta` | 18.2 GB | ext4 `/` | 2.2 GB/s | yes (`small_bfd`) |
| `uniref90_2022_05.fa` | 71.8 GB | ext4 `/` | 2.2 GB/s | yes (primary) |
| `mgy_clusters_2022_05.fa` | 128.6 GB | **symlink → `/mnt/e`** | 168 MB/s | yes (`mgnify`) |
| `uniprot_all_2021_04.fa` | 108.4 GB | ext4 `/` | — | paired-MSA annotation only |
| `pdb_seqres_2022_09_28.fasta` | 223 MB | ext4 `/` | — | template search |
| `mmcif_files/` | 7354 files | ext4 `/` | — | templates |

`mgy_clusters_2022_05.fa` is a symlink to `<models-root>\af3_db_extra\`, i.e. it
is **not** on ext4. `du -sh /db/*` reports `0` for it — that is `du` not
following the symlink, not a truncated file. Use `stat` on the link target.

## Why jackhmmer, not MMseqs2

An earlier revision of this skill prescribed an MMseqs2 index. That is no longer
runnable here: `createdb` + `createindex` on bfd alone costs ~43 GB, and the WSL
vhdx lives on `D:`, which had only 22 GB of headroom above its hard 50 GB floor.

The MMseqs2 argument ("HMMER rescans the whole database per query") is true but
irrelevant at this scale — we are folding a handful of complexes, not doing
genome-scale annotation. AF3 itself uses jackhmmer against exactly these files.

`oih_shared_msa.py` therefore imports **AF3's own**
`alphafold3.data.tools.jackhmmer.Jackhmmer` instead of shelling out to the
binary. Search parameters and the Stockholm→a3m conversion are then identical to
`run_alphafold.py --db_dir=/db`. Defaults taken from
`alphafold3/data/pipeline.py`: `n_iter=1`, `e_value=1e-4`,
`max_sequences=10000` (uniref90) / `5000` (bfd), and `z_value` **left unset**
(unsharded DB; AF3's `--*_z_value` flags default to `None` and
`run_af3.sh` never sets them).

## Commands

Search one FASTA and write a3m per chain:

```bash
/alphafold3_venv/bin/python <tools-dir>/oih_shared_msa.py \
  --fasta query.fasta --outdir /msashared/out --dbs uniref90,bfd --n-cpu 12
```

Wire an OpenDDE job (search + inject `unpairedMsaPath` + emit a validation
manifest):

```bash
/alphafold3_venv/bin/python <tools-dir>/wire_opendde_msa.py \
  --job job.json --out job_msa.json --dbs uniref90,bfd --n-cpu 12
```

Wire an ESMFold2 job from the *same* OpenDDE job file, reusing the same cache:

```bash
/alphafold3_venv/bin/python <tools-dir>/wire_esmfold2_msa.py \
  --job job.json --out job_esm.json --variant full --dbs uniref90,bfd --n-cpu 12
```

Validate the a3m files with OpenDDE's own parser:

```bash
/opendde_venv/bin/python <tools-dir>/validate_a3m_for_opendde.py \
  --pairs <out>/msa/_validate_pairs.json
```

Exit 0 = every file usable, 2 = at least one would silently degrade to a
query-only MSA at prediction time.

## The a3m dialect OpenDDE needs

`RawMsa._verify_query` does **not** compare row 0 to the query as a string; it
compares the *shape* of `sequences_to_array([self.seqs[0]])` to the query's.
`MSA_PROTEIN_SEQ_TO_ID` contains uppercase keys only, and

```
cols = sum(1 for c in sequences[0] if c in cmap)
```

so **row 0 must be the query, all uppercase, with no lowercase insertions** — a
row of the right length but containing insertion columns is accepted by the
shape check and then mis-featurised. AF3's own output satisfies this
(`>query` + the exact target sequence), which is the main reason to reuse its
wrapper rather than writing a converter.

Also: MMseqs2/ColabFold a3m often carry trailing NUL bytes and an off-by-one row
count. `validate_a3m_for_opendde.py` checks NUL count, row-0 identity, and that
every aligned row shares one width.

## Measured on this box

12 CPU threads, `-N 1 -E 1e-4`, `--no-cache`:

| Database | Size | Query | Wall clock | Rows |
|---|---|---|---|---|
| bfd | 18.2 GB | 127 aa camelid VHH | **346.9 s** | 226 |
| bfd | 18.2 GB | 284 aa unannotated model | 571 s | **7** ⚠️ |
| uniref90 | 71.8 GB | 127 aa camelid VHH | **>62 min, abandoned** | — |

First hit for that query included `A0A091EFX1_FUKDA/21-117` and `/226-322` —
two camelid VHH domains from PDB **FUKDA**, which is the correct answer for a
VHH query and is not something a broken pipeline produces by accident.

`uniref90,bfd` merged and capped at depth 2048. ESMFold2-Fast exists because CDR depth is structurally limited.
antibodies: CDRs are somantically recombined and have no deep alignment, which

Depth is not the bottleneck for antibodies: CDRs are semantically recombined
and have no deep alignment. What *is* the bottleneck is whether the database
actually contains your query's homologues.

### What bfd actually contains

Measured over the whole 18 GB file (66,000,000+ sequences):

| Content | Count | Example headers |
|---|---|---|
| Influenza A | 1297 | `Q1HB27_9INFA`, `C6L806_9INFA`, `A0A0C6EH81_9INFA` |
| HIV-1 | 328 | `A0A1U9AAP6_9HIV1` |
| MGnify ERR (environmental rRNA) | ~4.4 M of the first 20 M sampled | `ERR1043166_5944305` |
| AlphaFold DB accessions | ~378 k of the first 20 M sampled | `A0A091EFX1_FUKDA` |

**Headers are UniProt mnemonics plus a 5-letter organism code, never species
names.** Influenza A appears as `_9INFA` / `_5INFA` / `HEMA_`.

### Two ways to draw a *wrong* conclusion from a header census

Both of these were wrong here before being caught:

1. `grep -i -c '^>.*influenza' bfd` → **0**, which reads as "bfd has no
   influenza". Wrong: the word never appears in these headers. There were 1297
   influenza entries all along.
2. Searching the first 4 M lines for `A0A091EFX1` → **0**, while jackhmmer had
   *already hit that exact accession*. Wrong: **bfd is shuffled**, so a head
   slice proves nothing.

**Rule: a census must cover the whole file, match the right token, and include a
positive control that is known to exist.** Here the control was `^>A0A091EFX1`
(= 1, so the method worked). Without a control you cannot tell "absent" from
"my search term was wrong".

### Prefilter sensitivity, measured

Same query, same database, only AF3's F1/F2/F3 changed:

| Filters | Rows | influenza headers | Wall clock |
|---|---|---|---|
| AF3 defaults `5e-4 / 5e-5 / 5e-7` | 7 | 0 | 571 s |
| **disabled** (`10 / 10 / 10`) | **16** | **0** | 2275 s |

Disabling the prefilters costs **4x the time** and recovers 9 rows, none of them
influenza. On this query the filters were not the bottleneck. AF3's own comment
calls those values "set very low to make querying Mgnify run in a reasonable
amount of time" — aggressive, but not obviously wrong.

### Why the 7 rows were what they were

The antigen in RFantibody's `flu_HA.pdb` example input is a **theoretical model
with no annotation**: `EXPDTA THEORETICAL MODEL`, `HEADER 07-NOV-22`, and no
TITLE / COMPND / SOURCE / SEQRES. Its sequence has no influenza HA signal
peptide, no `PKYVKQ` fusion loop, and no coronavirus spike markers. **The name
"flu_HA" comes only from the filename.**

With the prefilters off and the database known to hold 1297 influenza entries,
the query still returns zero influenza homologs. So the correct conclusion is
that **the query is not influenza HA**, and the six non-query rows
(`ERR1043166_5944305/53-91`, `/155-197`, ... — 39-58 aa subsegments of a single
MGnify environmental rRNA entry) are **spurious local matches**.

Carry that forward: **check hits for internal coherence before trusting a depth
number.** Six hits that are six windows of the same unrelated entry are not six
independent homologues, and a "deep" alignment can be one protein repeated.

### What MSA did and did not buy (OpenDDE, abag checkpoint, seed 1)

| Metric | no MSA | with MSA (bfd) | change |
|---|---|---|---|
| ipTM | 0.1860 | 0.3243 | +74% |
| gPDE | 1.902 | 1.362 | -28% (lower is better) |
| pTM | 0.4747 | 0.5726 | +21% |
| forward | 66.74 s | 218 s | 3.3x |

Do **not** read the ipTM jump as "epitope placement improved". It came from the
nanobody chain (225 rows of real FUKDA homologues); the antigen chain
contributed nothing. ipTM is a global confidence scalar with no interface
discrimination — this project has measured it *rising* when the antigen is
deleted entirely. **gPDE dropping 1.902 → 1.362 is the result worth keeping.**

## Consumers

**OpenDDE** — set `unpairedMsaPath` only. Do **not** set `pairedMsaPath`:
a genuine paired alignment needs a cross-chain search, which per-chain
jackhmmer does not do. OpenDDE handles the absence correctly — the paired
alignment becomes query-only and `msa_pair_as_unpair` concatenates the unpaired
rows on top. That is exactly what `search_and_build_msa` does when its paired
ColabFold call fails, so it is a supported path, not a degraded one.

**ESMFold2** — `protforge-esmfold2/scripts/fold.py` reads
`{"msa": {"A": "/path/a.a3m"}}` from the job JSON and reports
`msa_used/msa_requested` in its metrics file. `variant: "fast"` has no MSA
encoder and drops them with a warning; only `full` is MSA-conditioned.

## Do not validate on a head slice

A truncated slice of `bfd` cannot validate this pipeline. Measured earlier: the
rat EPO motif `TKVNFYAWKR` has **0 exact matches in the first 400,000 bfd
sequences**. bfd is shuffled, so a head-slice search returns zero hits and looks
like a broken pipeline when it is working correctly. Validate against the full
database, or a deliberately shuffled sample large enough to contain homologs.
A zero-hit result is only meaningful once you know the search space contains the
query — the scripts print a warning when a database returns only the query row.

## Traps

| Trap | What happens | Correct |
|---|---|---|
| `wsl.exe -- bash -c "... > /new/dir/log ..."` | PowerShell strips the redirection **and the script still runs**, with the redirect words arriving as `$1` | `mkdir` the dir in an earlier call; put every `>`/`&`/`<` inside a `.sh` launcher |
| reading a cache hit as the search time | reports 0 s for a search that takes 6 min | re-run with `--no-cache` to measure |
| `createindex <fasta> idx` | `Database … needs header information`, rc=1 | needs `createdb` first — this is why the MMseqs2 route was dropped |
| `convert2a3m` | `Invalid Command` | `result2msa --msa-format-mode 2` then `convert2fasta` |
| trusting a "0 hits" result | looks like a broken pipeline | see "head slice" above |
| trusting `--dbs` defaults to mean AF3's full set | mgnify is silently skipped | mgnify is opt-in because it lives on `/mnt/e` at 168 MB/s |

## Failure handling

- `huggingface.co` refused → unrelated to MSA, but set
  `HF_ENDPOINT=https://hf-mirror.com` so nothing tries to fetch assets.
- **WSL reclaimed mid-job** — this is silent and loses everything. Long jobs need BOTH `setsid nohup` inside WSL *and* a host-side `wsl.exe -d AF3Native -- sleep infinity` launched via `Start-Process -WindowStyle Hidden`. An in-VM `/root/heartbeat.sh` is NOT enough: it dies with the VM and cannot keep the VM alive. Diagnose a reclaim by comparing `cat /proc/sys/kernel/random/boot_id` and `/proc/uptime` against your last note — a reclaimed VM shows a new boot_id and a few seconds of uptime, with nothing in the job log. Anything cached on disk survives, so keep the MSA cache outside the job script and simply re-run the step.
  - Search returns only the query row → the sequence is genuinely novel (common for
  designed binders); that is a correct answer, not a failure.