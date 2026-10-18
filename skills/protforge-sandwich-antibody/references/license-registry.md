# 外部工具许可证登记表

**核实日期：2026-10-18。** 这份表回答一个反复出现的问题：有人（论文、推荐、
自己）提出某个模型能不能进 ProtForge 管线。答案不是「看起来开源」，而是这一行。

## 怎么读这张表

- **判定** 一栏只写**核实过的一手证据**：仓库 `LICENSE` 文件、官方 README 的
  License 段、或 SPDX 元数据。三者都没有 = **未声明**。
- **未声明 ≠ 可用。** 没有 LICENSE 文件的仓库默认保留所有权利，法律上不可商用，
  哪怕源码全部公开、论文开放获取。**论文的 CC 条款和软件的许可条款是两回事**，
  混淆这两者是本项目最常见的一类错误。
- **代码许可和权重许可是两笔账。** 代码 MIT 不代表权重能商用；反之亦然。
- 表格会过期。**用它之前先重新核一遍**，不要凭这张表做决定。

## 已采纳（可商用）

| 工具 | 许可 | 核实依据 | 用途 |
|---|---|---|---|
| **ParaSurf** | **MIT** | 仓库 `LICENSE` + README「This project is licensed under the MIT License」 | 抗体条件化互补位预测，补上「抗体未知」表位预测的缺口 |
| **PolyXpert** | 代码 **MIT** / 权重 **CC-BY-4.0** | 仓库 `LICENSE` + HuggingFace 模型卡 license 字段 | 聚反应性（序列级，ELISA 背景信号） |
| **AbDev** | **MIT** | 仓库 `LICENSE`（2024-12-21） | 12 项理化性质；见下方「采用但未做成技能」 |
| **Boltz-2** | **MIT**（代码+权重） | 官方技术报告与仓库声明 | 抗体-抗原结构 + 亲和力；见下方「未装但可用」 |
| **AbLang2** | **BSD-3-Clause** | 上游声明 | 抗体语言模型，OpenGerminal 用它替代 IgLM |
| **Chai-1** | **Apache-2.0** | 上游声明 | 共折叠模型 |
| **OpenGerminal** | **Apache-2.0** | 论文「under the Apache 2.0 license」+ 仓库 | 去 PyRosetta/IgLM 的 VHH 设计流水线；**不是 VH/VL 配对评分器** |

## 已拒绝

| 工具 | 实际许可 | 为什么拒 |
|---|---|---|
| **tFold / tFold-Ag** | **PolyForm Noncommercial License 1.0.0** | 仓库 `LICENSE` 原文「You must agree the software license terms … only to non-commercial use purposes」。GitHub SPDX 亦为 `NOASSERTION`。腾讯 AI4S，抗体-抗原复合物 DockQ 0.217。**不可商用** |
| **AbNatiV2 / p-AbNatiV2** | **CC BY-NC-SA 4.0** | README 与 PyPI 元数据原文：「This software is not to be used for commerical purposes」。370 万配对人类序列，天然配对 top-1 74%。**不可商用** |
| **ImmunoMatch** | **CC-BY-NC-4.0** | 基于 AntiBERTa2；模型许可限制商用。**不可商用** |
| **AbEpiTope-1.0** | **无 LICENSE 文件** | `https://api.github.com/repos/mnielLab/AbEpiTope-1.0/license` 返回 **404**。论文为 CC BY-NC，但**软件许可未声明** → 默认保留所有权利。**不可商用** |
| **ImmunoCheck** | **未核实** | 「学术与商用均免费」这一说法只在一个 BiStars 论坛回复里出现，**没有**来自工具方的声明。免费 API ≠ 可再分发的管线。**在核实到一手条款前不采用** |
| **IgLM / PyRosetta** | 各自非商用 / 自定义 | Germinal 自身论文承认这是它「受限」的原因 |

## 三个被误判的「缺口」

### 1. AbEpiTope-1.0 不是表位预测器

它的两个输出是 **AbEpiScore-1.0**（这个 AbAg 复合物建模准不准）和
**AbEpiTarget-1.0**（这是不是真配对，用来区分真配对 vs 交换抗体的假配对，
rank-1 准确率 61.73%）。**它不输出表位残基。** 把它当成「预测表位是否零重叠」
的工具是范畴错误——即使许可允许也用不上。

它真正适合的位置是：**判断某个 AbAg 建模结果是否可信**，而不是判断两个表位
是否打架。这件事 ProtForge 现在用别的办法做（见下）。

### 2. p-AbNatiV2 和 OpenGerminal 都解决不了 VH-VL 配对问题

- p-AbNatiV2 是配对likelihood模型，但**非商用**。
- OpenGerminal 是 Apache 2.0，但它做的是 **VHH 从头设计**（Chai-1 + AbLang2），
  **没有 VH/VL 配对打分输出**。

所以「最优先插入的第二项」实际上一项都插不进来。

**而且在本管线下这个问题本来就不存在。** 交付的 VH 和 VL 来自同一个真实晶体
结构（框架 100% 保留），VH-VL 配对是**继承来的、已知的**，不是预测出来的。
换 CDR 确实可能扰动配对，但那是二阶效应而且**可以直接量**——见
`antibody-structural-invariants.md` 第 7 条。**花一个模型的代价去买一个本来
就有的答案，是错配。**

### 3. 「免疫原性」是治疗性抗体的指标，不是检测试剂盒的

ImmunoCheck / IgLM / AbEpiTope 这条线的 MHC-II 表位免疫原性评分，针对的是
**抗体被注入人体**的场景。检测试剂盒里的抗体**不进入人体**，免疫原性对它没有
决策意义。把它搬过来当质控项属于指标错配。

对试剂盒真正有意义的是**背景信号**：聚反应性 / 非特异结合 → ELISA 非特异信号、
高背景、动态范围压缩。这一项由 PolyXpert 覆盖。

## 未装但可用：记下来，别重复调研

- **Boltz-2**（MIT，代码+权重）：同时出结构和亲和力信号，抗体-抗原体系明确覆盖。
  当前**没有装**——ProtForge 已有 OpenDDE（FoldBench-AB 76.1%）和 ESMFold2
  （58.1%）两个复合物预测器，DiffDock 只作盲对接兜底。**再加第三个结构预测器
  不解决当前瓶颈**；真要加，加在「三元复合物可行性检查」那一步，而不是替换主力。
  装它要 GPU + 权重 + 独立运行时，属于明确的成本决策，不是默认动作。
- **AbDev**（MIT，12 项理化性质）：**未做成技能**，两个原因——① 官方接口是
  notebook（`DeepSP.ipynb` → `AbDev.ipynb`），没有 CLI，写 runner 就要读它的内部
  函数调用，那正是本项目明令禁止的「凭印象写命令」；② 训练集只有 **137 个 mAb**
  的实测值，把回归模型用到 in-silico 设计出的全新 CDR 上属于分布外推断。它适合
  做**同类已表达抗体的粗排**，不适合做设计阶段的门。需要时按 notebook 流程手动跑。
- **OpenGerminal**（Apache 2.0）：VHH 设计，与「常规 VH/VL 夹心对」不是一回事。
  若目标抗原适合纳米抗体路线（尺寸小、需穿透组织、或需避免 Fc），它是 ProtForge
  现有栈里唯一**全栈可商用**的从头 VHH 设计流水线，值得作为一条独立路线评估。

## 怎么用这份表

新工具进来时，先在「已采纳 / 已拒绝」之间做一次判定，把**证据**（LICENSE 文件
URL 或 README 段落）连同日期写进表里。**没有证据的行不要写。**
如果一个工具被拒但缺口仍然存在，在「三个被误判的缺口」里补一条——说明用什么
**不需要许可证**的办法把这个缺口关掉。
