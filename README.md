# ProtForge

> 23 个计算生物学技能的可移植 Agent 插件包 — 结构预测、蛋白与 binder 设计、分子对接、
> 分子动力学、表位预测、糖基化感知验证。

ProtForge 把一批成熟的开源计算生物学工具包装成 Agent 可路由的技能：每个工具一个
skill，附带自己的输入约定、命令、输出契约和踩坑记录。它不重新实现这些工具，而是
解决「怎么让 Agent 正确地把它们串起来跑」。

---

## 这个包里有什么

| 技能 | 工具 | 运行时 | 用途 |
|---|---|---|---|
| `protforge-overview` | — | — | 路由器：工具地图 + 共享约定 |
| `protforge-alphafold-db` | AlphaFold DB | 宿主机 | 按 UniProt 下载公开预计算结构（免费，先查再算） |
| `protforge-esmfold2` | ESMFold2 | WSL | 蛋白结构预测（当前主力，已取代 AlphaFold 3） |
| `protforge-opendde` | OpenDDE | WSL | 复合物预测 + 逐界面评分 |
| `protforge-af3-msa` | MSA builder | WSL | 为 ESMFold2 `full` 变体生成 MSA |
| `protforge-rfdiffusion` | RFdiffusion | Docker | 从头设计骨架 / binder 骨架 |
| `protforge-proteinmpnn` | ProteinMPNN | Docker | 基于骨架的序列设计 |
| `protforge-pesto` | PeSTo | Docker（复用 proteinmpnn 容器） | PPI 界面 / 热点预测 |
| `protforge-bindcraft` | BindCraft | Docker | 端到端 binder 设计（未做端到端验证，见下方说明） |
| `protforge-reglyco` | ReGlyco | 宿主机 | 糖基化感知的设计校验 |
| `protforge-fpocket` | fpocket | Docker | 结合口袋检测（经典几何法） |
| `protforge-p2rank` | P2Rank | Docker | 结合口袋检测（机器学习） |
| `protforge-vina-gpu` | Vina-GPU | Docker | GPU 快速对接（需给定盒中心） |
| `protforge-gnina` | GNINA | Docker + 宿主机 | CNN 对接，可对姿态重打分 |
| `protforge-diffdock` | DiffDock | Docker | 盲对接（不给结合位点） |
| `protforge-autodock-gpu` | AutoDock-GPU | Docker | AutoDock4 GPU 对接（需自备 `.maps.fld` 网格） |
| `protforge-gromacs` | GROMACS | Docker | 分子动力学（蛋白体系） |
| `protforge-esm` | ESM-2 | Docker | 序列嵌入 / 拟困惑度 |
| `protforge-chemprop` | Chemprop | Docker | ADMET 预测（仅 ESOL 溶解度模型） |
| `protforge-discotope3` | DiscoTope3 | Docker | B 细胞表位预测 |
| `protforge-igfold` | IgFold | Docker | 抗体 / 纳米抗体折叠 |
| `protforge-freesasa` | FreeSASA | 宿主机 | 溶剂可及表面积 + ADC 偶联位点 |

### 三个运行时，互不混装

ProtForge 刻意把运行时分开，因为它们的 CUDA 构建互不兼容，混装会崩：

| 运行时 | 覆盖技能 | 说明 |
|---|---|---|
| Docker 容器 | 对接、口袋、MD、序列设计、表位、ADMET、抗体折叠、骨架设计 | 每个工具一个预构建镜像 |
| WSL venv | ESMFold2、OpenDDE | 各自锁定 CUDA 版本，详见对应 SKILL.md |
| 宿主机进程 | AlphaFold DB、FreeSASA、ReGlyco | 不需要 Docker，也不需要 GPU |

---

## 安装

在各 Agent 客户端的「插件 → 导入插件」里粘贴本仓库地址：

```
https://github.com/dy12021/protforge.git
```

GitHub 仓库子目录导入：在 URL 末尾追加 `?path=<subdir>` 或使用 `/tree/main/<subdir>` 形式。

也可以下载发布包手动安装（见「发布物」）。

---

## 前置条件

> ⚠️ **本仓库只包含技能定义，不包含镜像、模型权重或 compose 文件。**
> 你需要自己准备好下面这些，`scripts/_common.sh` 会把它们连起来。

- **Docker Desktop**（或 WSL2 + Docker Engine）— 容器化工具需要
- **NVIDIA GPU** — 单卡 16 GB 是下限；ESMFold2 `full` 变体建议 24 GB 以上
- **WSL2** — ESMFold2 / OpenDDE / MSA 需要；CUDA 构建按技能固定，勿跨 venv 混装
- **模型权重** — 放在 `$PROTFORGE_MODELS` 下，由各工具 skill 的 SKILL.md 说明目录约定
- **compose 文件** — `_common.sh` 会在 `$PROTFORGE_HOME` 下自动查找
  `protforge-platform/` 或 `oih-platform/` 子目录中的 `docker-compose.windows.yml`

### 目录约定

```
$PROTFORGE_HOME/            # 数据与模型根，默认 E:/protforge
├── data/
│   ├── inputs/             # 放输入文件
│   └── outputs/<job>_<tool>/   # 每个任务一个输出目录
├── models/                 # 模型权重（挂载进容器，不在本仓库内）
└── protforge-platform/     # 你的 compose 文件
```

### 挂载契约（最容易踩的一坑）

`PROTFORGE_MOUNT` 默认是 `/data/protforge`，所以你的数据目录必须挂到这个点，
**默认任何 runner 都会找不到容器内的路径**。如果你的部署同时还在用旧版的
`/data/oih` 路径，**不要替换它，要两个都挂**：

```yaml
volumes:
  - <data-root>:/data/oih            # 旧工具链仍在硬编码这个路径
  - <data-root>:/data/protforge      # ProtForge 的规范挂载点
  - <models-root>/rfdiffusion:/data/protforge/models/rfdiffusion:ro
  - <models-root>/admet:/data/protforge/models/admet:ro
```

`rfdiffusion` 和 `chemprop` 的权重在规范路径下找不到时，runner 会打印一行
`... is missing; falling back to the host models path` —— 那不是致命错误，
但请按上表把挂载补齐。

---

## 站点本地配置

**本仓库不含任何机器专属路径。** 你的数据/模型根写在 gitignore 的
`scripts/local.env` 里，永远不会被提交或发布：

```bash
cp scripts/local.env.example scripts/local.env
$EDITOR scripts/local.env
```

| 键 | 作用 |
|---|---|
| `PROTFORGE_CANDIDATES` | 空格分隔的候选根目录，按顺序探测，第一个存在即采用 |
| `PROTFORGE_DEFAULT_ROOT` | 所有候选都不存在时的兜底值 |
| `ESMFOLD2_MODELS_ROOTS` | ESMFold2 权重目录的额外探测点（WSL 路径，冒号分隔） |

`scripts/local.env.example` 是模板，会随仓库一起发布。

---

## 环境变量

所有环境变量都是可选的，不设时用默认值。

| 变量 | 默认值 | 说明 |
|---|---|---|
| `PROTFORGE_HOME` | `$PROTFORGE_CANDIDATES` 首个存在项，兜底 `E:/protforge` | 数据与模型根 |
| `PROTFORGE_DATA` | `$PROTFORGE_HOME/data` | 输入 / 输出目录 |
| `PROTFORGE_MODELS` | `$PROTFORGE_HOME/models` | 模型权重 |
| `PROTFORGE_COMPOSE` | 自动探测 | compose 文件路径 |
| `PROTFORGE_MOUNT` | `/data/protforge` | `$PROTFORGE_DATA` 在容器内的挂载点，**必须与你的 compose 映射一致** |
| `PROTFORGE_VENV` | 探测 | 宿主机 venv（FreeSASA、GNINA 的 SMILES 预处理用） |
| `PROTFORGE_CONTAINER_<TOOL>` | `protforge-<tool>` | 单个容器名覆盖，如 `PROTFORGE_CONTAINER_VINA_GPU` |

变量名前缀是 `OIH_` 的旧变量仍被兼容（`OIH_HOME` / `OIH_DATA` / `OIH_MOUNT` /
`OIH_CONTAINER_<TOOL>`），改名之前建的部署不需要改任何配置。

---

## 输出契约

每个 runner 结束时会打印一行状态标记：

```
PROTFORGE_STATUS: OK
PROTFORGE_STATUS: FAIL <原因>
```

**以 `PROTFORGE_STATUS:` 结尾是唯一可靠的成功信号。** 一个跑到一半 traceback、
没有状态标记就结束的脚本，即使退出码是 0，也要按失败处理。

部分工具还会额外打印 `PROTFORGE_OUTPUT_DIR:`、`PROTFORGE_CIF:`、
`PROTFORGE_BACKBONES:` 等字段。

---

## 改技能前必读：frontmatter 会被静默丢弃

`SKILL.md` 开头的 YAML frontmatter 如果解析失败，**加载器会把这个技能直接丢掉，
不报任何错**。实际踩过的坑：本包一度声明 23 个技能、实际只注册 5 个，
原因就是 18 个 `description` 写成了裸标量，而值里有 `Trigger: When ...`
这种「冒号+空格」，PyYAML 会抛
`ScannerError: mapping values are not allowed here`。

规矩只有一条：**`description` 这类自由文本一律加双引号**（内部 `"` 和 `\` 要转义）。

### 校验

```bash
bash check_syntax.sh        # 所有 shell 脚本的语法
bash test_common_rename.sh  # 改名兼容层（路径解析 / 容器名 / 输出契约）
python test_frontmatter.py  # 每个 SKILL.md 的 frontmatter 是否真的能解析
```

三个都必须全绿再提交。改完 `description` 后至少跑一次 `test_frontmatter.py` ——
它用加载器的方式 parse 前言块，检查能否解析、有没有 `name`/`description`、
以及 `name` 是否和目录名一致。

---

## 已知限制

- **AlphaFold 3 已在本包中退役。** `protforge-alphafold3` 仅保留给仍需用它做校验
  交集的场景，结构预测的主力是 ESMFold2 和 OpenDDE。另外 AlphaFold 3 **不可商用**。
- **`protforge-bindcraft` 未做端到端验证。** 早前文档称它「启动即抛
  `NameError: pr`」，该说法已过期：当前镜像的 `bindcraft.py` 已有
  `PYROSETTA_AVAILABLE` 守卫，PyRosetta 缺失时走 PyRosetta-free 模式。
  真正踩到的问题是 runner 硬编码了规范容器名，在仍用 `oih-*` 命名的部署上
  会 `No such container`——这一点已修复。完整设计要跑数小时，尚未在此环境跑通，
  首次使用请先小规模验证。可用替代：`protforge-fpocket` 选热点 →
  `protforge-rfdiffusion` 生成骨架。
- **`protforge-chemprop` 只会算溶解度。** 它默认加载 ESOL 检查点；如果你问的是毒性、
  hERG、BBB 透过或 CYP 抑制，请直接说没有安装对应模型，不要拿溶解度数字代替毒性结论。
- **`protforge-opendde` 的聚合 `iptm` 不能用于 Ab-Ag 界面筛选。** 删掉抗原后聚合
  ipTM 反而会升高，说明它被另一对紧界面拉高、对目标界面零分辨力。要看逐界面的
  `chain_pair_gpde`。

---

## 发布物

每个发布都带两个压缩包：

| 文件 | 内容 |
|---|---|
| `protforge-<版本>-plugin.zip` | 完整插件包：两份 manifest、`scripts/`、`skills/`、图标、README、LICENSE |
| `protforge-<版本>-skills.zip` | 手动安装用：`skills/` + `scripts/_common.sh` |

skills 包必须带上 `scripts/`——runner 用的是相对路径
`$(dirname $0)/../../../scripts/_common.sh`，缺了它整个技能树都起不来。

---

## 许可与出处

**本仓库的技能定义与脚本以 MIT 发布。** 但它包装的第三方工具各自遵循其原始许可，
使用前请自行确认：

| 组件 | 许可 |
|---|---|
| ESMFold2 / ESMC | MIT |
| OpenDDE | Apache-2.0 |
| ReGlyco | AGPL-3.0（GlycoShape 数据 CC BY-NC-ND，仅限学术） |
| AlphaFold 3 | **不可商用** |
| 其余各工具 | 遵循各自上游仓库的许可 |

仓库中的 `icon.png` / `icon-dark.png` 同样适用 MIT。
