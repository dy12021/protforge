---
name: protforge-polyxpert
description: "Score antibody polyreactivity from Fv sequences alone with PolyXpert (MIT code, CC-BY-4.0 weights; fine-tuned ESM-2 150M, runs on CPU). Trigger: When the user asks about polyreactivity, non-specific binding risk, high ELISA background, nonspecific binding of a capture/detection pair, or wants a cheap sequence-level developability gate before synthesis or ordering. Sequence-only -- needs no structure."
---

# PolyXpert — 序列级聚反应性

对**检测试剂盒**来说，聚反应性是唯一直接对应「背景信号」的序列级属性：一条
高聚反应性的抗体会结合无关表面，在夹心 ELISA 里表现为高本底、动态范围压缩、
钩状效应。这不是治疗性抗体的指标错配，是同一个物理现象在试剂盒里的直接后果。

模型只吃 **VH/VL 的 Fv 序列**，不需要结构，ESM-2 150M 量级，**CPU 可跑**。
所以它属于本工作流里最便宜的一档门——放在序列检查之后、任何 GPU 计算之前。

**许可：代码 MIT，权重 CC-BY-4.0**（HuggingFace `zhouyw/PolyXpert` 模型卡）。
两者都可商用，但 CC-BY 要求署名。核实依据见
`protforge-sandwich-antibody/references/license-registry.md`。

上游：`github.com/zzyywww/PolyXpert`，
论文 <https://doi.org/10.1016/j.jpha.2025.101448>。

## 上游的实际接口（从源码读出来的，不是从 README 推的）

```
python PolyXpert.py <inputfile>
```

- 输入：`pd.read_csv(..., sep='\t')` —— **制表符分隔**，三列 `Name` / `VH` / `VL`。
  列名大小写敏感，顺序无所谓。
- **必须从仓库根目录运行**：模型从 `./PolyXpert` 相对路径加载。
- **`results/` 目录必须预先存在**：上游直接 `to_csv('./results/...')`，
  pandas 不会创建目录，缺了就 `FileNotFoundError`。
- 输出：`results/pred_results_<时间戳>.txt`，制表符分隔，列为
  `proba_0` / `proba_1` / `pred_label`，以 `Name` 为索引。
- `O/B/U/Z` 会被上游自动替换成 `X`——**不要**因此放过含这些字符的序列，
  它们不是标准残基，属于别的缺陷。
- 有 GPU 用 GPU，没有则回落 CPU。

## 前置条件（照下面这条走，每一步都有原因）

```bash
conda create -n polyxpert python=3.9
conda activate polyxpert
git clone https://github.com/zzyywww/PolyXpert.git
cd PolyXpert

# CPU torch is enough -- this is sequence scoring, no structure involved.
# Upstream pins 1.13.1; its CUDA build is ~2 GB and torch 1.13.1 tops out at
# CUDA 11.7 anyway, while the rest of the stack runs on CPU in seconds.
pip install torch==1.13.1 --index-url https://download.pytorch.org/whl/cpu

# Upstream says "pip install -r requirements.txt --ignore-installed".
# DO NOT trust --ignore-installed here: it drags in numpy 2.x, and
#   ValueError: numpy.dtype size changed ... Expected 96 from C header, got 88
# is what pandas 1.5.3 does when loaded against numpy 2. Install the pins, then
# pin the two transitives that upstream forgot:
pip install datasets==2.9.0 pandas==1.5.3 tqdm==4.64.1 transformers==4.26.1
pip install "numpy==1.26.4"     # pandas 1.5.3 + transformers 4.26.1 predate numpy 2
pip install "pyarrow==12.0.1"   # datasets 2.9.0 uses pa.PyExtensionType, gone in pyarrow 15
```

权重：`https://i.uestc.edu.cn/PolyXpert.zip`（或 HuggingFace `zhouyw/PolyXpert`）。

**权重解压出来的目录叫 `esm2_finetuning/`，不是 `PolyXpert/`——上游 README 这里写错了。**
而 `PolyXpert.py` 从相对路径 `./PolyXpert` 加载，所以必须重命名：

```bash
unzip PolyXpert.zip
mv esm2_finetuning PolyXpert     # 必须是这个名字
```

最终 `$PROTFORGE_POLYXPERT_HOME/` 下应有：`PolyXpert.py` 与 `PolyXpert/`
（内含 `config.json`、`pytorch_model.bin`、`special_tokens_map.json`、
`tokenizer_config.json`、`vocab.txt`）。


## 命令

```bash
bash "${PLUGIN_DIR}/skills/protforge-polyxpert/scripts/polyxpert.sh" \
     "$input_tsv" "$job_name" "$polyxpert_home"
```

- `$input_tsv` — 制表符分隔，`Name`/`VH`/`VL` 三列
- `$job_name` — 输出目录名，默认取输入文件名
- `$polyxpert_home` — PolyXpert 仓库根，默认 `$PROTFORGE_MODELS/PolyXpert`

runner 会把结果复制到 `$PROTFORGE_DATA/outputs/<job>_polyxpert/`，
并打印每条候选的 `proba_1` 与 `pred_label`。

## 怎么用这个分数——先读这一段再用

**它不是「低于某个数就通过」的判据。** 上游没有发布推荐阈值，本技能也不会
给你编一个。要用成门，必须先在项目里显式定阈值并写下来；不能因为分数不好看
再回头调。

三条必须写进报告的限制：

1. **训练分布是治疗性抗体。** 训练数据是真实治疗抗体的 Fv。你的候选是
   in-silico 设计出的 CDR 嫁接到真实人源框架上——框架在分布内，**CDR 在
   分布外**。把它当**风险指示**，不是概率。
2. **它是二分类，不是亲和力。** `proba_1` 是「被判为高聚反应性」的概率，
   **不是**「结合强度」。不要拿它排序亲和力。
3. **成对评估。** 夹心对的两条抗体**分别打分，然后看高的一条**。高背景来自
   任意一条，而不是两条的平均。

**不要用它替代**：`protforge-abdev` 之类的理化性质模型（覆盖更宽）、
以及任何湿实验的 ELISA 非特异结合对照。本项目**不提供**后者——
在报告里明说是计算候选。

## 坑

- `Name` 重复时，`set_index` 后的结果行数会与输入对不上而很难排查。
  runner 已经拒绝重复名。
- 序列含非标准字符时上游替换成 `X` 然后照常打分，**不会报错**。
  runner 在调用前就拦掉。
- 输出写在 PolyXpert 仓库里的 `results/`，不在你的数据目录。
  runner 会复制出来，别去仓库里翻。
- 上游把 NCCL 的 P2P / IB 通信在 import 时关掉了。多卡机器上不要指望它用多卡。
- **runner 要在 Git Bash 下跑，不要用 WSL 的 bash。** 脚本用 `E:/...` 盘符路径，
  而这个 conda 环境是 Windows 原生二进制（含 `.pyd`），WSL 的 python 加载不了。
- `PROTFORGE_POLYXPERT_PYTHON` 必须是**单个可执行文件**（如
  `C:/Users/<user>/.conda/envs/polyxpert/python.exe`）。runner 用 `command -v`
  校验，写成 `conda run -n polyxpert python` 这样的多词字符串一定失败。
- 输出目录名会再追加 `_polyxpert` 后缀，job 名别自己带这个后缀，否则出现
  `xxx_polyxpert_polyxpert`。

## 已验证的运行（2026-10-18）

本技能已在本机端到端跑通：22 条输入（上游 5 高 + 5 低聚反应性对照 + 12 条
BDNF 夹心候选），全部产出 `pred_results.txt`，`PROTFORGE_STATUS: OK`。

**对照组必须能分开**，否则这次运行不算数：

| 分组 | proba_1 | pred_label |
|---|---|---|
| 上游 5 条高聚反应性对照 | 0.9995 – 0.9997 | 全 1 |
| 上游 5 条低聚反应性对照 | 0.0007 – 0.2428 | 全 0 |
| BDNF 12 条候选 | 0.0015 – 0.0459 | 全 0 |

**怎么读这组数**：候选全部落在低聚反应性区间，没有观察到聚反应性风险信号。
但**不能说「已证明低聚反应性」**——设计的 CDR 得分比真实低聚反应性治疗抗体对照
还低，这本身就**加重**了分布外的疑虑：模型训练于真实治疗抗体，而候选是嫁接出来
的新 CDR。所以这只能作为**排除性证据**（没看到危险信号），不能作为**肯定性证据**
（证明背景低）。分布内表现强 + 分布外推断弱，是这类模型在设计阶段的通病。

