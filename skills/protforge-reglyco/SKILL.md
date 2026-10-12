---
name: protforge-reglyco
description: |
  Glycosylation-aware validation and filtering for protein design work (ReGlyco /
  GlycoShape). Runs on the HOST, not in a container - reglyco is a native Rust
  CLI (`cargo install reglyco`) that fetches MD-derived glycan ensembles from
  glycoshape.org. Trigger when the user asks about N-glycosylation sites,
  whether a glycosylation site is occupied/accessible (GlcNAc scan), whether a
  designed binder clashes with the glycans on a glycoprotein target, or wants
  glycan-aware filtering of a binder design set ("糖基化", "糖链冲突",
  "glycan clash", "glycoform"). This is the tool that answers whether a binder
  designed on a DEGLYCOSYLATED model still binds the real glycosylated protein.
---

> Note: `${PLUGIN_DIR}` is the absolute install path of this plugin
> (`${PLUGIN_DIR}` for this installation).

# ReGlyco / GlycoShape — glycosylation-aware design validation

> **New in the v2 upgrade.** Every binder-design tool in ProtForge (RFdiffusion,
> BindCraft, ProteinMPNN, AF3) consumes a **deglycosylated** structure. For a
> glycoprotein that is a real problem: the glycans occupy real surface, and
> designs aimed at a surface the sugar actually covers will fail in the wet lab.
> ReGlyco is the missing validation hop.

Host CLI, no Docker. Binary comes from crates.io:

```bash
cargo install reglyco --locked --version 0.1.0
```

Licence note: **ReGlyco (github.com/Ojas-Singh/Re-Glyco) is AGPL-3.0-only.**
GlycoShape data is CC BY-NC-ND (academic). Both are fine for research; neither
is safe to ship inside a commercial product. Check before commercial use.

## Commands

### 1. GlcNAc scan — which sequons are actually occupied?

```bash
reglyco scan --protein target.pdb --glycan G14843DJ --output out/scan
```

Fits a single GlcNAc into every `N-X-S/T` sequon and reports which pass.
`scan.json` lists per-site independent accessibility plus joint-subset
membership; `structure.pdb` holds only the mutually compatible subset.
Blocked sites are never written with placeholder coordinates.

Add `--calculate-hotspots` to emit the binder-design mask.

### 2. Build — attach specific glycans and resolve clashes

```bash
reglyco build --protein target.pdb \
  --attach A:64=G98687PM \
  --rotamers --population 64 --generations 30 \
  --report --output out/build
```

Each `--attach CHAIN:RESIDUE=GlyTouCanID`. `G55818EE`, `G63547QM`,
`G68783EM`, `G72008IY` are the IDs used in the authors' own EPO demo.

### 3. Ensemble — sample attached conformations

```bash
reglyco ensemble --protein target.pdb --attach A:64=G98687PM \
  --frames 10 --seed 7 --output out/ens
```

Draws from native cluster/phi/psi distributions and rejects only incompatible
frames. Protein coordinates stay fixed unless `--move-sidechains` is passed.

### 4. Relax — energy minimise

```bash
reglyco relax --input out/build/glycoprotein.pdb \
  --movable glycans --max-iterations 200 --output out/relaxed
```

Vacuum force field by default; `--obc2` for solvent-aware but far slower.

## The binder-clash test (the important one)

Feed the **full predicted complex** — target chain *plus* the designed binder —
to `build`. If the glycan cannot be attached at a site, or the report flags
clashes against the binder, the design targets surface that does not exist in
the real glycoprotein.

```bash
reglyco build --protein my_complex.pdb \
  --attach A:50=G55818EE --attach A:64=G68783EM --attach A:109=G63547QM \
  --rotamers --report --output out/clash
```

Authors' triage convention (used for the Nipah binder competition set, where
this filtered 11% of 1201 designs in ~3 CPU-hours):

- **Pass** — no clashes after the first optimisation pass
- **Borderline** — clears only after rotamer-enabled local adjustment
- **Fail** — clashes persist even after the rotamer pass

## Practical notes

- Numbering is the **input PDB's** numbering, not UniProt. AF3 renumbers a mature
  chain from 1, so convert before choosing `--attach` sites.
- Ensemble data is fetched from `https://glycoshape.org` (Levels 2–3 are not
  served to CLI clients). `glycoshape.io` is retired.
- Glycan **microheterogeneity** is the norm: one site carries several structures,
  so a filter that passes for one GlyTouCan ID does not clear the whole family.
- Neighbouring loops occupy real surface, so scanning the native
  AlphaFold/RFdiffusion output, not a stub, is what makes the numbers mean
  something.

## Failure handling

- `error: invalid GlyTouCan ID` — look the ID up on glycoshape.org.
- Timeout (4000 s hard limit per job) — reduce sites or use `--no-report`.
- Attachment "genuinely infeasible" — that site is blocked; treat as Fail rather
  than retrying with different seeds.