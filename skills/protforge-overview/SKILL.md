---
name: protforge-overview
description: "Overview of the ProtForge plugin — 26 computational-biology skills (containerized tools, WSL-hosted models, host-side clients), how they are wired to three runtimes, paths, conventions, and prerequisites. Trigger: When the user asks what bio tools are available or how the plugin is organized"
---


> Note: `${PLUGIN_DIR}` is the absolute install path of this plugin. Resolve it
> from the plugin context and substitute before invoking any command below.

# ProtForge — overview

26 skills wrapping computational-biology tools. This file is the router: it owns
the tool map, which of the three runtimes each skill uses, and the shared path
and output conventions. Each individual skill's `SKILL.md` is the source of truth
for its own invocation.

## Three runtimes

ProtForge deliberately keeps three runtimes apart. Mixing CUDA builds between
them causes crashes, so never install one runtime's packages into another.

| Runtime | Used by | Notes |
|---|---|---|
| Docker containers | docking, pockets, MD, sequence design, epitope, ADMET, antibody folding | one prebuilt image per tool |
| WSL venvs | ESMFold2, OpenDDE | pinned CUDA builds; see each skill |
| Host processes | AlphaFold DB client, FreeSASA, ReGlyco, PolyXpert | no Docker; PolyXpert runs on CPU |

## Tool map

| Skill | Tool | Runtime | Purpose |
|-------|------|---------|---------|
| `protforge-overview` | — | — | this router |
| `protforge-alphafold-db` | AlphaFold DB | host | precomputed public models by UniProt accession |
| `protforge-esmfold2` | ESMFold2 | WSL | protein structure prediction (main AF3 replacement) |
| `protforge-opendde` | OpenDDE | WSL | complex prediction + per-interface scores |
| `protforge-af3-msa` | MSA builder | WSL | MSA generation helper for ESMFold2 `full` |
| `protforge-rfdiffusion` | RFdiffusion | Docker | de novo backbone / binder backbone design |
| `protforge-proteinmpnn` | ProteinMPNN | Docker | sequence design on a backbone |
| `protforge-pesto` | PeSTo | Docker (shares proteinmpnn) | PPI interface / hotspot prediction |
| `protforge-bindcraft` | BindCraft | Docker | end-to-end binder design — **currently blocked**, see below |
| `protforge-reglyco` | ReGlyco | host | glycosylation-aware validation of a design |
| `protforge-fpocket` | fpocket | Docker | binding pocket detection (classical) |
| `protforge-p2rank` | P2Rank | Docker | binding pocket detection (ML) |
| `protforge-vina-gpu` | Vina-GPU | Docker | fast GPU docking, needs a box centre |
| `protforge-gnina` | GNINA | Docker + host | CNN docking, also rescores poses |
| `protforge-diffdock` | DiffDock | Docker | blind diffusion docking (no site given) |
| `protforge-autodock-gpu` | AutoDock-GPU | Docker | AutoDock4 GPU docking, needs a `.maps.fld` grid |
| `protforge-gromacs` | GROMACS | Docker | molecular dynamics (protein-only) |
| `protforge-esm` | ESM-2 | Docker | sequence embeddings / pseudo-perplexity |
| `protforge-chemprop` | Chemprop | Docker | ADMET prediction (ESOL reference model) |
| `protforge-discotope3` | DiscoTope3 | Docker | B-cell epitope prediction (**antibody-agnostic**) |
| `protforge-parasurf` | ParaSurf | host + manual install | paratope-antigen interface prediction (**antibody-conditioned**) |
| `protforge-polyxpert` | PolyXpert | host, CPU | sequence-only polyreactivity (assay background) |
| `protforge-igfold` | IgFold | Docker | antibody / nanobody folding |
| `protforge-freesasa` | FreeSASA | host | SASA + ADC conjugation sites |
| `protforge-sandwich-antibody` | — (workflow) | — | sandwich capture+detection pair design: constraints, ordering, multi-seed reporting |

## Licensing

Any third-party model entering the pipeline must be cleared for commercial use
**before** it is written into a workflow — not after. `protforge-sandwich-antibody`
carries the registry with per-tool evidence in
`references/license-registry.md`; the three cases worth knowing before you
recommend anything:

- **No LICENSE file means all rights reserved**, even when the paper is open
  access. AbEpiTope-1.0 is in this position.
- **tFold-Ag is PolyForm Noncommercial**, so the usual "leading Ab-Ag model" is
  not an option for a commercial pipeline. Boltz-2 (MIT) is.
- **Code licence and weights licence are separate.** PolyXpert is MIT code and
  CC-BY-4.0 weights.

Diagnostic reagents and therapeutics also need different gates: immunogenicity /
MHC-II scoring is meaningful for a drug, not for an antibody that never enters a
human. Background signal — polyreactivity — is what matters for an assay.

## Deprecated and blocked

- **AlphaFold 3 is retired here.** `protforge-alphafold3` is kept because several
  skills still validate against it, but ESMFold2 and OpenDDE are the primary
  structure-prediction path. AlphaFold 3 is also **not commercially usable**.
- **`protforge-bindcraft` fails at launch** in the current image: the PyRosetta-free
  stub still calls `pr.init(...)` and dies with `NameError: pr`. Say this up front
  rather than letting it surface after hotspots are set up. The workable substitute
  is `protforge-fpocket` for hotspots plus `protforge-rfdiffusion` for backbones.

## Conventions

- Data root: `$PROTFORGE_HOME` (default `<data-root>`). Inputs go in
  `$PROTFORGE_DATA/inputs/`, outputs land in `$PROTFORGE_DATA/outputs/<job>_<tool>/`.
- Model weights live in `$PROTFORGE_HOME/models/` and are mounted into containers.
  They are **not** part of this repository.
- **Containers resolve through `protforge_exec` / `protforge_ensure_container`, which
  start a stopped container via the compose stack (`$PROTFORGE_COMPOSE`, auto-discovered
  under `$PROTFORGE_HOME`). `protforge_container` falls back to a legacy `oih-<tool>`
  container name, so pre-rename deployments keep working unchanged.
- Every runner prints `PROTFORGE_STATUS: OK` or `PROTFORGE_STATUS: FAIL <reason>`.
  **Treat a run that ends without a `PROTFORGE_STATUS:` line as a failure**, even if
  the script exited 0.
- Verify availability first: run the tool's smoke command from its own `SKILL.md`
  before committing GPU hours to a long job.

### Site-local paths go in `scripts/local.env`

`scripts/local.env` is gitignored and never published; copy it from
`local.env.example`. Put anything machine-specific there — data root candidates,
extra model roots, and the checkout path of **host-side** tools that are not
containers (e.g. `PROTFORGE_POLYXPERT_HOME`, `PROTFORGE_PARASURF_HOME`,
`PROTFORGE_POLYXPERT_PYTHON` pointing at that env's `python.exe`, which must be a
single executable because runners resolve it with `command -v`).

### Use domestic mirrors inside container builds

A build that fetches from `archive.ubuntu.com`, `repo.anaconda.com` or `pypi.org`
measured ~2.5 MB/s on this host, which is not enough to install a CUDA torch wheel
set inside any reasonable build timeout. When building an image, point every source
at a domestic mirror — `protforge-parasurf`'s `Dockerfile.protforge` is a working
example:

| 源 | 换成 |
|---|---|
| apt | `https://mirrors.tuna.tsinghua.edu.cn/ubuntu` |
| conda | `https://mirrors.tuna.tsinghua.edu.cn/anaconda/cloud/conda-forge` |
| pip | `https://pypi.tuna.tsinghua.edu.cn/simple` via `PIP_INDEX_URL` |

The base-image pull goes through the host's registry mirror and is unaffected.

Two further traps worth knowing before writing a Dockerfile:

- **Anaconda's Terms of Service block non-interactive `conda create`** against the
  default channels. Use `--override-channels -c conda-forge` instead of running
  `conda tos accept` — accepting a licence on the operator's behalf is not an
  automated build step.
- **Run long builds detached from the calling task** (`... > build.out.log 2> build.err.log &`).
  A build killed by a task timeout leaves a truncated log and no image, which looks
  exactly like a network stall.