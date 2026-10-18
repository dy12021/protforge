---
name: protforge-sandwich-antibody
description: "End-to-end sandwich ELISA/CLIA antibody-pair design: oligomer-aware pose, CDR sequence design with canonical-residue and glycosylation constraints pinned, geometry-ordered candidate screening, multi-seed relaxation, and honest reporting. Trigger: When the user wants a capture + detection antibody pair for a sandwich assay (夹心 ELISA, 夹心法, 双抗, capture/detection antibody, antibody pair, epitope pairing). Not for therapeutic antibodies, VHH/nanobody binders, or affinity maturation of an existing binder."
---

# ProtForge — sandwich antibody pair design

Design the pair, and do not ship a pair whose acceptance criteria were
satisfied by accident. This skill is the router: it orders the other ProtForge
tools and pins the constraints that must enter *before* sequence design.

## Non-negotiables

Ranked by how expensive each failure is. All four were observed in a real run
(`references/defect-log.md`).

1. **Constraints are generation inputs, not output filters.** Disulfide,
   glycosylation and packing constraints go into the ProteinMPNN call. A filter
   cannot resolve a conflict with the designer's own preference: when the sampler
   commits to a residue in 100% of samples, filtering deletes the whole set.
2. **Assert the target invariant, never a proxy.** "No cysteine in the CDR" is a
   proxy for "the native disulfide network is intact". The proxy stayed green
   while `--omit_AAs C` deleted the conserved Cys that forms half of the VH
   intradomain disulfide.
3. **The validation layer must not be structurally identical to the generation
   layer.** An epitope read off the same docking that produced the pose is
   circular: it catches transcription errors, never modelling errors.
4. **Any distance criterion is conformer-dependent.** One restrained relaxation
   samples one conformer. Report a distribution, never a single value.

## Procedure

### 0. Antigen facts

- Take the sequence from the primary record. Do not trust a remembered length;
  a widely repeated precursor length can be wrong.
- Record precursor vs mature chain and the mature range explicitly.
- Count N-X-S/T sequons on the antigen (`protforge-reglyco` does this properly).
- Establish the real oligomeric state. A secreted dimer is the species in the
  tube; the monomer interface is a face the antibody cannot reach in the sample.

### 1. Pose — treat it as a hypothesis

- Dock against the **full oligomer** as the obstacle. Docking one monomer exposes
  the buried dimer interface and selects epitopes no assay will see.
- Anchor by CDR tips, not centroid: an Fv is ~45 Å wide, and a centroid offset
  of 12–19 Å buries half of it.
- Rank by **interface CDR fraction**, not total contacts. A framework-dominated
  interface means the scaffold is parked on the antigen.
- Pair selection must require **both** non-overlapping epitopes **and** Fv–Fv
  clearance.
- Antibody–antigen docking success is low even for leading models. Record the
  pose as a hypothesis and plan step 7.

### 2. Pin the sequence constraints before designing

Build the ProteinMPNN `fixed_positions_jsonl` (see `protforge-proteinmpnn`;
its JSON is **1-based**, the code subtracts 1 internally — verify against the
source rather than inferring from output, because a degenerate sampler and an
off-by-one look identical):

- Framework and both antigen chains: fixed.
- **Conserved Cys opening CDR-H3** (VH Cys22–Cys96 disulfide): pin it. Do **not**
  use a blanket `--omit_AAs C`; that ban deletes the conserved residue along with
  the strays, and the strays are what the ban was for.
- **Any CDR position where ≥50% of samples build an N-X-S/T sequon**: pin it back
  to the parent residue and re-run. Designability constraints are inputs.

### 3. Sequence-level acceptance — before any expensive relaxation

Cheap, and it catches the most damaging defects. Do not proceed past a failure
here (`references/antibody-structural-invariants.md` for exact assertions):

- Conserved disulfide network intact: every Cys position vs the parent scaffold.
- No N-X-S/T sequon inside a CDR.
- Only standard residues — ProteinMPNN emits `X`, and such a design passes
  length, framework and structure round-trip checks.
- Framework identical to the parent at every position.
- Declared CDR sequences match the declared numbering.

### 4. Order candidates by geometry, not by score

A backbone-frozen dock makes **which CDR positions touch the antigen a property
of the pose, not of the design**; only the side chain attached to each differs.
Score by side-chain bulk summed over those positions and spend the relaxation
budget on the lean ones.

Do not order by the ProteinMPNN sequence score. That measures sequence
plausibility, not geometry: one pose returned 0/6 under a score ordering and
16/79 under a bulk ordering, and was nearly discarded as "too tight a pose".

### 5. Relax and evaluate over several seeds

`references/relaxation-and-screening.md` has the exact recipe and the failure
signatures. Non-negotiables:

- Set velocities **after** minimisation (before it, every design diverges to NaN).
- Derive the seed **per design** from the design's own coordinates. A global seed
  destabilises all designs coherently; no seed makes the result a random draw.
- Guard non-finite coordinates and persist each result as it is produced.
- Evaluate every geometric criterion over several seeds; report
  min / median / max and the fraction that clear the bar. **1/4 conformers is
  not a pass.**

### 6. Record the sandwich geometry

Fv–Fv clearance and epitope non-overlap, measured on the delivered side chains —
and again per seed, for the same reason.

### 7. Independent cross-check

The epitope came from the docking that produced the pose. Cross-check with
`protforge-discotope3`, whose failures differ from a rigid-body dock's.
Disagreement is information. Do not re-fold an Fv with `protforge-igfold` when a
crystal scaffold is already in hand.

### 8. Report honestly

- Parent-pose and delivered-sequence numbers in **separately labelled blocks**,
  never same-named fields at the same level. Every number names the file it was
  measured on.
- Distinguish **FAIL** (a claim contradicts the data — fix the pipeline) from
  **GAP** (a real limitation — disclose it).
- Never move a threshold to make a shortfall disappear.
- State that the result is a computational candidate. Immobilisation effects,
  real-matrix background and labelling damage are not computable.

## Tool routing

| Step | Tool | Runtime |
|------|------|---------|
| 0 antigen glycosylation | `protforge-reglyco` | host |
| 1 pose | `protforge-vina-gpu` / `protforge-gnina` / `protforge-autodock-gpu` | Docker |
| 1 interface scoring | `protforge-freesasa` | host |
| 2–4 sequence design | `protforge-proteinmpnn` | Docker |
| 4 hotspot context | `protforge-pesto` | Docker |
| 5 relaxation | GROMACS or OpenMM (`protforge-gromacs` for the container) | Docker |
| 7 independent epitope | `protforge-discotope3` | Docker |

## Output contract

- Capture and detection as full heavy + light chains, variable domains and
  constant regions stated separately.
- Per antibody: a single-conformer measurement **and** a multi-seed distribution.
- The selection criterion stated.
- Disclosed limitations, including the ones not met.
- Structure files that carry the delivered sequences themselves, so every claim
  is checkable against coordinates.

## Reviewing an existing design

Run step 3 first. It is minutes of work, and in one project it found a deleted
native disulfide and a glycosylation site on the antigen-contacting loop — both
invisible to every structural metric, both of which a structural-only review
passes.

## References

- `references/antibody-structural-invariants.md` — conserved residues, CDR
  numbering, and which items are assertions versus commentary.
- `references/relaxation-and-screening.md` — relaxation recipe, seeding,
  NaN guard, multi-seed evaluation, geometry-ordered screening.
- `references/defect-log.md` — defects from a real run: symptom, root cause,
  how each was detected, and why the original check missed it.

## Platform notes

- `${PLUGIN_DIR}` must be resolved and substituted before any command below.
- Windows: `docker exec` from PowerShell needs no bash wrapper; under Git Bash
  set `MSYS_NO_PATHCONV=1` or `/app/...` gets rewritten to a Windows path.
  Nested PowerShell → `wsl -e bash -lc` → shell quoting breaks; write the script
  to a file and run the file.
- Isolate CUDA builds per runtime (see `protforge-overview`). Mixing a Docker
  CUDA build with a WSL venv causes crashes.
- Keep scripts in this skill's `scripts/`; keep bulky material in `references/`.
