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
> (for this installation).

# ReGlyco / GlycoShape — glycosylation-aware design validation

> **New in the v2 upgrade.** Every binder-design tool in ProtForge (RFdiffusion,
> BindCraft, ProteinMPNN, AF3) consumes a **deglycosylated** structure. For a
> glycoprotein that is a real problem: the glycans occupy real surface, and
> designs aimed at a surface the sugar actually covers will fail in the wet lab.
> ReGlyco is the missing validation hop.

Host CLI, no Docker. Binary comes from crates.io:

```bash
# 版本号别抄旧文档：**0.1.0 已被上游撤下**（crates.io 上 reglyco 只剩
# 0.2.0 / 0.2.1 / 0.2.2 / 0.2.3）。0.2.x 全部要求 **rustc ≥ 1.97**
# （实测装 0.2.3 时报 "requires rustc 1.97 or newer, while the currently
# active rustc version is 1.96.0"）——先 `rustup update stable` 再装。
cargo install reglyco --locked --version 0.2.3
```

上游 0.2.x 把工程拆成了 workspace（`reglyco-core` / `reglyco-build` /
`reglyco-relax` / `reglyco-cli` …），但**可执行文件仍由 `reglyco` 这个 crate
提供**（它的 `bin_names` 就是 `reglyco`）；`reglyco-cli` 只是库侧那一份，
装它不会给你命令行。

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

**`--calculate-hotspots` 不在 `scan` 上了**（实测 0.2.3：`scan --help` 里没有它，
但 `ensemble --help` 里有，别名 `hotspots`）。要出 binder-design mask 就用
`ensemble`：

```bash
reglyco ensemble --protein target.pdb --glycan G14843DJ \
  --calculate-hotspots --output out/ens
```

（`scan` 其余参数、`build`/`relax`/`ensemble` 文档里写的那些选项在 0.2.3 都还在。）

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

## 调用接口（手动模式）

入口 `scripts/protforge-reglyco.sh`（宿主原生 CLI，不在容器里）：

| # | 参数 | 说明 |
|---|---|---|
| 1 | `pdb_path` | 要检查的结构 |
| 2 | `subcommand` | `scan` / `ensemble` / `build` / `relax`，默认 `scan` |
| 3 | `glycan` | GlyTouCan ID，默认 `G14843DJ` |
| 4 | `attach` | `build` 专用，格式 `A:64=G98687PM`，多个用 `;` 隔 |
| 5 | `hotspots` | 默认 `false`（只有 `ensemble` 有 `--calculate-hotspots`） |
| 6 | `job_name` | 平台会自动加 `t<任务号>_` 前缀 |

产物在 `$PROTFORGE_DATA/outputs/<job_name>_reglyco/`：`scan.json`、
`structure.pdb`（只含彼此兼容的位点）、`report.json`。

> **做 binder 冲突测试时喂完整复合物**（靶标链 + 设计出来的 binder），
> 不是脱糖的裸靶标。编号用的是**输入 PDB 的编号**，不是 UniProt——
> AF3 会把成熟链从 1 重新编号，选 `attach` 位点前要先换算。
