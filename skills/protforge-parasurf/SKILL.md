---
name: protforge-parasurf
description: "Predict antibody-specific paratope-antigen interaction interfaces with ParaSurf (MIT, Bioinformatics 2025), as an independent cross-check of a docked Ab-Ag pose. Trigger: When the user wants a paratope prediction, a paratope-antigen interface map, an antibody-conditioned (not antibody-agnostic) epitope check, or an independent second opinion on which antigen residues a given antibody binds. Distinct from protforge-discotope3, which cannot see the antibody at all."
---

# ParaSurf — 抗体条件化互补位预测

DiscoTope3 回答「蛋白表面哪些区域可能被**任意**抗体识别」——它**不看抗体**。
当候选表位来自一个具体的抗体-抗原对接位姿时，DiscoTope3 无法区分「我的抗体
结合这里」和「这里是个好表位」。ParaSurf 输入抗体的三维结构，输出**互补位-抗原
相互作用界面**，正好补上这个缺口。

**许可：MIT**（仓库 `LICENSE`，见 `protforge-sandwich-antibody/references/license-registry.md`）。
论文开放获取许可（CC BY 4.0）与软件许可是两回事，这里用的是前者与 MIT 并不冲突。

上游：`github.com/aggelos-michael-papadopoulos/ParaSurf`，
论文 <https://doi.org/10.1093/bioinformatics/btaf062>。

## 这是交叉验证，不是打分

**用法：验证一个已有的对接位姿 / 一对已有抗体。**

不要把 ParaSurf 当成「生成位姿」的工具——它不建模结合模式，输出的是界面区域。
当表位是从对接里读出来的时候，用 ParaSurf 复核的价值正在于**它的失败模式与刚体
对接不同**：它看互补位与抗原表面的几何契合，不看对接打分函数。两者不一致就是
信息，不要和成平均。

## 前置条件（都满足才往下走）

ParaSurf 的安装比本插件其他工具重，**不要在跑通之前提交 GPU/机时**：

| 前置 | 要求 | 备注 |
|---|---|---|
| Python | 3.10 conda 环境 | `pip install -r requirements.txt` |
| OpenBabel | conda-forge | 化学数据预处理 |
| `dms` C++ 库 | `cd dms && make install` | 表面分子表示的构建后端 |
| `PYTHONPATH` | 指向 ParaSurf 仓库根 | 缺了会 import 失败 |
| 模型权重 | **Google Drive 手工下载** | 见下 |

**权重在 Google Drive，不是 pip 包、不是 HF。** 每个基准数据集一条链接
（PECAN / Paragraph Expanded / 全文-重链-轻链 / MIPE 五个 fold）。选定一个
基准，下载对应权重，放到 `$PROTFORGE_MODELS/parasurf/`。

### Windows 上走 Docker

`make install` 在 Windows 上不是一条能直接抄的命令。上游提供了 Dockerfile，
**Windows 优先用 Docker 路线**：

```bash
git clone https://github.com/aggelos-michael-papadopoulos/ParaSurf.git
cd ParaSurf && cat Docker/README.md     # 上游自己的安装说明，以它为准
```

本插件**没有**预构建 `protforge-parasurf` 镜像，也**不提供**开箱即用的
compose 服务——这是刻意的：仓库不携带镜像构建，权重也要手工下载。
装好之后用下面的 runner 调用。

## 先确认输入契约，再跑

**上游 README 的散文和命令行标志名不一致**：正文说「Run a blind prediction on
an **antibody** file」，而标志是 `--receptor`，示例文件叫 `4N0Y_receptor_1.pdb`。
这两者不能同时字面成立。

**装好之后第一件事是读它自己的帮助，不要照抄本文档：**

```bash
python "${PARASURF_HOME}/blind_predict.py" --help
```

确认它到底要**抗体结构**、**抗原结构**，还是**复合物**。下面的 runner 按 README
字面传 `--receptor`，如果你 `--help` 读出来不是这个语义，**改 runner，不要改
结论**。

## 命令

```bash
bash "${PLUGIN_DIR}/skills/protforge-parasurf/scripts/parasurf.sh" \
     "$pdb_path" "$job_name" "$weights_dir"
```

- `$pdb_path` — 绝对路径，或 `inputs/` 下的文件名（按 `--help` 确认的语义准备）
- `$job_name` — 输出目录名，默认取输入文件名
- `$weights_dir` — ParaSurf 权重目录，默认 `$PROTFORGE_MODELS/parasurf`

批量：

```bash
python "${PARASURF_HOME}/blind_predict_folder.py" \
       -i <目录> -w <权重> -d 0.2
```

## 读结果

输出目录：`$PROTFORGE_DATA/outputs/<job>_parasurf/`

- runner 打印 `PROTFORGE_STATUS: OK` / `FAIL`，以及 `PROTFORGE_PARASURF_FILES:`
  列出的产出文件。
- 界面预测的落盘格式以本次运行实际产出为准——**先 `ls` 再写报告**，
  不要照抄上游截图里的列名。上游没有承诺稳定 schema。

## 报告时怎么写

- 给出**两条表位**：对接位姿推出来的那条，和 ParaSurf 独立预测的那条。
- 报告**两者的交集和差集**，分别是什么残基。
- 不一致时**不要**取并集当结论，也不要调阈值让它们对上。写清楚哪个工具在哪个
  残基上分歧，分歧本身就是交付信息。
- ParaSurf 只说「这里像是个界面」，**不说「这里亲和力高」**。不要把界面预测
  当亲和力证据。

## 坑

- **权重不在 pip / HF，在 Google Drive。** 没有权重时脚本会 fail，
  不要让它跑出一个空输出然后当成「预测了 0 个界面」。
- `dms` 没编译时，报错出现在**跑预测时**而不是安装时，看起来像模型坏了。
- 上游提供了 HuggingFace Space 和多个商业平台（Superbio / Neurosnap /
  tamarind / Vici.bio / proteinIQ）。那是**别人的托管服务**，
  管线里要走本地安装——托管服务的条款和 MIT 不是一回事。
