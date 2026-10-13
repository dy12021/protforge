---
name: protforge-overview
description: "Overview of the ProtForge plugin — 23 computational-biology skills (containerized tools, WSL-hosted models, host-side clients), how they are wired to three runtimes, paths, conventions, and prerequisites. Trigger: When the user asks what bio tools are available or how the plugin is organized"
---


> Note: `${PLUGIN_DIR}` is the absolute install path of this plugin. Resolve it
> from the plugin context and substitute before invoking any command below.

# ProtForge — overview

23 skills wrapping computational-biology tools. This file is the router: it owns
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
| Host processes | AlphaFold DB client, FreeSASA, ReGlyco | no Docker, no GPU required |

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
| `protforge-discotope3` | DiscoTope3 | Docker | B-cell epitope prediction |
| `protforge-igfold` | IgFold | Docker | antibody / nanobody folding |
| `protforge-freesasa` | FreeSASA | host | SASA + ADC conjugation sites |

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
- Containers resolve through `protforge_exec` / `protforge_ensure_container`, which
  start a stopped container via the compose stack (`$PROTFORGE_COMPOSE`, auto-discovered
  under `$PROTFORGE_HOME`). `protforge_container` falls back to a legacy `oih-<tool>`
  container name, so pre-rename deployments keep working unchanged.
- Every runner prints `PROTFORGE_STATUS: OK` or `PROTFORGE_STATUS: FAIL <reason>`.
  **Treat a run that ends without a `PROTFORGE_STATUS:` line as a failure**, even if
  the script exited 0.
- Verify availability first: run the tool's smoke command from its own `SKILL.md`
  before committing GPU hours to a long job.