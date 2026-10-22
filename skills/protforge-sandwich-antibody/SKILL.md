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

## Cost tiers — run the cheap gate before the expensive one

Never spend GPU hours on a candidate that a seconds-long check can reject.

| Tier | Cost | Content | Gate |
|------|------|---------|------|
| 0 | seconds, pure sequence | antigen facts; conserved Cys present; no CDR sequon; standard residues only; framework identical; CDR numbering self-consistent | **hard stop on failure** |
| 0b | seconds-to-minutes, pure sequence, CPU | polyreactivity (`protforge-polyxpert`) — costs one model load, no structure needed | **report both scores; gate only on a threshold written down in advance** |
| 1 | seconds, one pose read | contact-CDR positions; side-chain bulk ranking; dimer-interface blacklist | pick the order for Tier 2 |
| 2 | minutes per design | side-chain rebuild + restrained relaxation | interface metrics |
| 3 | minutes per design × seeds | multi-seed evaluation | robustness |
| 4 | expensive | independent cross-check, ternary-complex simulation | cross-validation |

## Metrics that must NOT be used to rank Ab–Ag candidates

- **ProteinMPNN sequence score / loss.** It measures how native-like the sequence
  looks. Ordering by it returned 0/6 where ordering by contact-surface bulk
  returned 16/79, on the same pose.
- **Aggregate ipTM.** Removing the antigen can *raise* it; it has no discriminative
  power here. Read per-interface contact counts, BSA and clash counts instead.
- **MM-GBSA / PRODIGY absolute values.** Two candidates whose interfaces differ by
  ~0.2 Å are far inside the method's noise; ranking them manufactures false
  precision. Useful only as a coarse tiebreak among clearly separated designs.
- **A single relaxation's minimum distance.** See non-negotiable 4.

## Time budget — probe small before scaling

Measured on 2026-10-22 (a 61-row batch): the median row took **8.4 hours**,
and the slowest commands were all **rigid-body search scripts run straight
into their timeout** (`place_fv_alt` / `place_fv_select` /
`place_fv_multiseed`, each 3000-3500 s). One command burns an hour and its
output may still be thrown away.

Rules:

1. **No single command over 10 minutes.** If a step needs longer, split it:
   run one seed / one conformer first (<= 2 min), check the result is sane,
   then scale up.
2. **Search scripts get probed small first.** Seeds, steps, grid resolution:
   start at the minimum, confirm it converges and the numbers are physical,
   then scale up.
3. **Two attempts per script, then change approach.** Editing the same script
   twice without success means the idea is wrong -- switch tools or change the
   criterion. Do not keep grinding it.
4. **Never use a timeout above 600 s.** A command that runs into its ceiling
   is usually spinning in place: cut it at 10 minutes and you still get the
   intermediate output, while 3500 s only gets you the word "timed out".
5. **Write the intermediate result to disk** before scaling up, so a killed
   run still leaves something behind.

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
- **Polyreactivity** via `protforge-polyxpert`, for **both** antibodies
  separately (Tier 0b). For a reagent, this is the one sequence-level property
  that maps directly onto assay background. Three constraints on its use:
  upstream publishes no threshold, so a gate needs a threshold written down *in
  advance* and never moved afterwards; the training set is therapeutic
  antibodies, so treat the score as a risk indicator on a designed CDR, not a
  probability; and **run the upstream high/low controls in the same batch** —
  a bare score with nothing to compare it against cannot be interpreted, and a
  run whose controls do not separate is a broken run, not a surprising result.
  Score below every known-low control is **not** proof of a clean antibody; it
  is a distribution-out-of-distribution symptom and must be reported as such.

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
- **Never use `nonbondedMethod=NoCutoff`.** It evaluates *all* N² atom pairs;
  with implicit solvent one energy+force call costs ~0.86 s at 6753 atoms, so a
  2000-iteration minimisation needs ~57 minutes and never finishes inside any
  practical command timeout. Use `CutoffNonPeriodic` with a 1.0–1.2 nm cutoff
  (OpenMM 8.x renamed `CutoffNonbonded`): ~0.05 s per call, ~3.3 minutes for
  the same minimisation — **17× faster**. *Pre-flight: time one
  `getState(getEnergy=True, getForces=True)`; above 0.5 s you are on the N² wall.*
- Add every `CustomExternalForce` **before** `Simulation(...)`, then
  `sim.context.reinitialize()`. A force added afterwards never reaches the
  Context: the restraint fails **silently** — the run looks healthy and the
  antibody drifts away from its pose.
- Enumerate the OpenCL devices (`getDevices()`) before choosing a platform, and
  fall back to CPU when the list is empty — do not hard-code a platform that may
  not exist, since that exception tends to surface only after a long run.
  *Measured here: OpenCL ≈ CPU (no discrete GPU exposed to the OpenCL runtime),
  so the cutoff is the win, not the platform.*

### 6. Record the sandwich geometry

Fv–Fv clearance and epitope non-overlap, measured on the delivered side chains —
and again per seed, for the same reason.

There is no off-the-shelf "sandwich ELISA pair scorer". If you want to rank
candidate pairs rather than pass/fail a single pair, compose a score from parts
that each mean something, and say in the report which parts they are:

- antibody-specific epitope predictions from the two antibodies (`protforge-parasurf`),
- their separation on the antigen surface,
- whether both Fv can be placed at once on the **full oligomer** — a steric
  coexistence check, which is a different and much easier question than whether
  the ternary complex is real,
- per-antibody BSA in the ternary assembly vs BSA alone, to catch one antibody
  being squeezed by the other's presence.

**What such a score cannot do:** it does not rank by affinity, and it does not
replace sequential-binding measurement. Coexistence is necessary, not sufficient.
Report the components separately as well as the total — a single fused number
hides which term is carrying the decision.

### 7. VH–VL pairing regression

In a CDR-graft route the VH and VL come from the **same crystal structure** and
the framework is unchanged, so the VH–VL pairing is inherited and known — it is
not something a predictor has to supply. The real risk is narrower: a grafted CDR
participating in the H–L interface (CDR-H3 and CDR-L1 sit on it) can pull the two
domains apart. Measure it, do not model it:

- H–L interface contact count and BSA on the **delivered** Fv, against the same
  quantity on the **parent** scaffold.
- Any VH or VL residue that is a CDR residue in the design but an H–L interface
  residue in the parent — check whether its side chain now points away from the
  partner chain.

Assert retention of the parent's interface, not an absolute threshold. A design
that loses a quarter of the parent's H–L BSA has a real problem even if it still
clears every other gate.

**Do not reach for a pairing-prediction model here.** The two obvious candidates
are unusable: `p-AbNatiV2` is CC BY-NC-SA 4.0 and states it is not for
commercial use, `ImmunoMatch` is CC-BY-NC-4.0, and `OpenGerminal` (Apache 2.0) is
a VHH design pipeline with no pairing output. See `references/license-registry.md`.

### 8. Independent cross-check

The epitope came from the docking that produced the pose. Cross-check with tools
whose failures differ from a rigid-body dock's — the criterion is **different
failure modes**, not "a second opinion":

- `protforge-parasurf` — **antibody-conditioned**: it sees the antibody, so it can
  answer "does *this* antibody bind *here*". This is the only cross-check in the
  stack with that capability; use it when it is available.
- `protforge-discotope3` — **antibody-agnostic**: it answers "is this a good
  epitope for *any* antibody". It cannot confirm an antibody-specific claim, so
  it corroborates the region, not the pairing.

Report the intersection **and** the difference. Disagreement is information.
Do not reconcile it by taking the union, and do not re-fold an Fv with
`protforge-igfold` when a crystal scaffold is already in hand.

### 9. Report honestly

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
| 3 polyreactivity | `protforge-polyxpert` | host, CPU |
| 4 hotspot context | `protforge-pesto` | Docker |
| 5 relaxation | GROMACS or OpenMM (`protforge-gromacs` for the container) | Docker |
| 6 ternary coexistence | `protforge-opendde` or `protforge-esmfold2` | WSL |
| 7 VH–VL interface | `protforge-freesasa` + a distance count | host |
| 8 independent epitope | `protforge-parasurf` (antibody-conditioned) / `protforge-discotope3` (region only) | host+Docker / Docker |

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
  numbering, VH–VL interface retention, and which items are assertions versus
  commentary.
- `references/relaxation-and-screening.md` — relaxation recipe, seeding,
  NaN guard, multi-seed evaluation, geometry-ordered screening.
- `references/defect-log.md` — defects from a real run: symptom, root cause,
  how each was detected, and why the original check missed it.
- `references/license-registry.md` — which external models may enter this
  pipeline, with the evidence and the date it was checked. Includes the tools
  that were rejected and what closes the gap instead.

## Platform notes

- `${PLUGIN_DIR}` must be resolved and substituted before any command below.
- Windows: `docker exec` from PowerShell needs no bash wrapper; under Git Bash
  set `MSYS_NO_PATHCONV=1` or `/app/...` gets rewritten to a Windows path.
  Nested PowerShell → `wsl -e bash -lc` → shell quoting breaks; write the script
  to a file and run the file.
- Isolate CUDA builds per runtime (see `protforge-overview`). Mixing a Docker
  CUDA build with a WSL venv causes crashes.
- Keep scripts in this skill's `scripts/`; keep bulky material in `references/`.
