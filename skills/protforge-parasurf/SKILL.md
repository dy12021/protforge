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

## 输入是抗体——标志名是错的

上游的标志叫 `--receptor`,但**传进去的必须是抗体结构**。源码里写着：

```python
parser.add_argument('--receptor', ..., help="Path to the receptor (antibody or paratope) PDB file.")
is_antibody, message = antibody_input_recognition(receptor)
if not is_antibody:
    print("Please provide a valid antibody structure as input."); exit(1)
```

README 正文说「on an antibody file」是对的,而变量名 `receptor` 是误导——代码自己
会校验并在不是抗体时 `exit(1)`。**ParaSurf 回答的是「给定这条抗体,它结合哪里」**,
这正是它与 DiscoTope3 的区别,也是它在交叉验证里的价值。传抗原进去会直接被判为
非法输入,不会给你一个假结果。

## 前置条件（都满足才往下走）

ParaSurf 的安装比本插件其他工具重，**不要在跑通之前提交 GPU/机时**：

| 前置 | 要求 | 备注 |
|---|---|---|
| Python | 3.10 conda 环境 | `pip install -r requirements.txt` |
| OpenBabel | conda-forge | 化学数据预处理 |
| `dms` C++ 库 | `cd dms && make install` | 表面分子表示的构建后端 |
| `PYTHONPATH` | 指向 ParaSurf 仓库根 | 缺了会 import 失败 |
| 权重 | **`.pth` 单文件**，每个基准一个 | 见下 |

权重是**文件不是目录**。上游给的是 Google Drive 链接（PECAN / Paragraph Expanded
/ 全文-重链-轻链 / MIPE 五个 fold），取法用 **`gdown`**——上游自己的
`Docker/README.md` 就是这么写的：

```bash
gdown --id 1nd3npYK303e8owDBvW8Ygd5m9SD1puhR -O weights/Paragraph_expanded_best.pth
```

### 走官方 Dockerfile，但必须先修两处

上游 Dockerfile **直接用会失败**，两个独立的原因。修复见同目录
`Dockerfile.protforge`。

**① Anaconda ToS 会挡住非交互构建**

上游装 `Miniconda3-latest` 后对默认 Anaconda 频道执行 `conda create`，在 Anaconda
的 ToS 机制下非交互构建直接报：

```
CondaToSNonInteractiveError: Terms of Service have not been accepted for:
    - https://repo.anaconda.com/pkgs/main
    - https://repo.anaconda.com/pkgs/r
```

修法有两条：`conda tos accept`，或**不碰 Anaconda 频道**。选后者——
**接受服务条款是代表使用者作出的法律行为，不该由构建脚本或代理代劳**：

```dockerfile
RUN conda create -n ParaSurf python=3.10 -y --override-channels -c <conda-forge>
```

**② 容器内全部走国外源，实测会慢到构建超时**

上游从 `archive.ubuntu.com`、`repo.anaconda.com`、`pypi.org` 取包。实测吞吐约
2.5 MB/s，仅 `torch==2.1.2` 的 CUDA 轮子组（约 2.5 GB 的 nvidia-* 包）就装不完，
构建直接冲破超时上限。**构建里所有源都要换成国内镜像**：

| 源 | 换成 |
|---|---|
| apt | `https://mirrors.tuna.tsinghua.edu.cn/ubuntu` |
| Miniconda | `https://mirrors.tuna.tsinghua.edu.cn/anaconda/miniconda/` |
| pip | `https://pypi.tuna.tsinghua.edu.cn/simple`（用 `PIP_INDEX_URL` 环境变量） |
| conda | `https://mirrors.tuna.tsinghua.edu.cn/anaconda/cloud/conda-forge` |

基础镜像那一层走宿主机的 registry 镜像加速器（见 `protforge-overview` 的部署约定），
不受此影响。实测换源后 apt 步骤从 150 秒级降到 20 秒级。

```bash
cd ParaSurf && docker build -t parasurf:latest -f Dockerfile.protforge .
```

本插件**不提供**预构建 `protforge-parasurf` 镜像——镜像带 CUDA 基础层且体积不小，
是否预构建应由部署方决定。

**长构建不要挂在交互任务上。** 构建超时被杀会留下"日志断在半路、镜像不存在"的
现场，看起来像网络卡死。正确做法是脱离任务超时独立运行，日志落盘：

```bash
docker build --progress=plain -t parasurf:latest -f Dockerfile.protforge . \
  > build.out.log 2> build.err.log &
```


## 命令

```bash
bash "${PLUGIN_DIR}/skills/protforge-parasurf/scripts/parasurf.sh" \
     "$antibody_pdb" "$job_name" "$weights.pth" "cuda"
```

- `$antibody_pdb` — **抗体**结构的绝对路径，或 `inputs/` 下的文件名
- `$job_name` — 输出目录名，默认取输入文件名
- `$weights.pth` — 权重**文件**路径，默认取 `$PROTFORGE_PARASURF_WEIGHTS`
- 第四个参数 `cuda` / `cpu`，默认 `cuda`

批量：

```bash
python blind_predict_folder.py -i <目录> -w <权重> -d 0.2
```

## 读结果

输出目录：`$PROTFORGE_DATA/outputs/<job>_parasurf/`

**上游把结果写在输入 PDB 旁边的目录里**：`<stem>_pred.pdb`（逐残基）、
`<stem>_pred_per_atom.pdb`（逐原子）、`centers.txt`、`pocket<N>.pdb`，运行期间还
会在同一目录留下临时 `*.surfpoints`（结束会删）。

所以 runner 会把输入**复制**一份到输出目录再跑——直接指向调用方的文件会在输入
目录里堆产物。

runner 打印 `PROTFORGE_PARASURF_RESIDUE_FILES`、`PROTFORGE_PARASURF_POCKETS`
和实际产出的文件列表。


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
