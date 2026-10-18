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
| OpenBabel | `openbabel-wheel` + X11 客户端库 | 化学数据预处理；**装法见下方 ④，不是 conda-forge** |
| `dms` C++ 库 | `cd dms && make install` | 表面分子表示的构建后端 |
| `PYTHONPATH` | 指向 ParaSurf 仓库根 | 缺了会 import 失败 |
| 权重 | **`.pth` 单文件**，每个基准一个 | 见下 |

权重是**文件不是目录**。上游只给 Google Drive 链接（PECAN / Paragraph Expanded
/ 全文-重链-轻链 / MIPE 五个 fold），取法用 **`gdown`**——上游自己的
`Docker/README.md` 就是这么写的：

```bash
gdown --id 1nd3npYK303e8owDBvW8Ygd5m9SD1puhR -O weights/Paragraph_expanded_best.pth
```

`Docker/README.md` 里给的三个 id：

| 文件 | gdown id |
|---|---|
| `ParaSurf_best.pth` | `1LBydgQ7sTXTAuEdE3Le_PH6cY_F2h_Tp` |
| `Pecan_best.pth` | `1vZGH-T6K5_ShVma3dwLkLdkoivs09rSP` |
| `Paragraph_expanded_best.pth` | `1nd3npYK303e8owDBvW8Ygd5m9SD1puhR` |

**先测 `drive.google.com:443` 通不通再决定取法。** 实测该环境不通，HuggingFace 上也
没有 ParaSurf 的权重仓库，官方 HF Space（`amelie-iska/ParaSurf`）的 `resolve/main/*.pth`
全部 404——它自己也是运行时从 Drive 拉的。**没有任何镜像能替代**，国内网络下只能由
使用者自行用浏览器/代理下载后放进 `$PROTFORGE_MODELS/parasurf/`。这一步走不通时，
如实记为 GAP，不要用未验证来源的权重跑预测。

### 走官方 Dockerfile，但必须先修五处

上游 Dockerfile **直接用会失败**，五个互相独立的原因。改好的完整文件在本技能
`references/Dockerfile.protforge`，下面逐条说明改了什么、为什么。它**不需要构建
上下文**——它自己会 `git clone` ParaSurf，所以空目录当 context 即可。

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
2.5 MB/s，仅 `torch==2.1.2` 的 CUDA 轮子组（约 2.3 GB 的 nvidia-* 包）就装不完，
构建直接冲破超时上限。**构建里所有源都要换成国内镜像**：

| 源 | 换成 |
|---|---|
| apt | `https://mirrors.tuna.tsinghua.edu.cn/ubuntu` |
| Miniconda | `https://mirrors.tuna.tsinghua.edu.cn/anaconda/miniconda/` |
| pip | `https://pypi.tuna.tsinghua.edu.cn/simple`（用 `PIP_INDEX_URL` 环境变量） |
| conda | `https://mirrors.tuna.tsinghua.edu.cn/anaconda/cloud/conda-forge` |

基础镜像那一层走宿主机的 registry 镜像加速器（见 `protforge-overview` 的部署约定），
不受此影响。实测换源后 apt 步骤从 150 秒级降到 20 秒级。

**③ 必须用 CPU torch，且必须按 URL 装**

上游 `requirements.txt` 钉的是 `torch==2.1.2`。**PyPI 上 linux 版的 torch 就是
CUDA 版**，会连带拉约 2.3 GB 的 nvidia-* 轮子——本机实测这段只有 0.04 MB/s，
等于十几小时，装不完。CPU 轮子 176 MB，实测 1.93 MB/s，约 90 秒。

但**不能这样写**：

```dockerfile
# 错：阿里云那个目录是平铺文件列表，不是 PEP 503 simple index
RUN pip install torch==2.1.2 --index-url https://mirrors.aliyun.com/pytorch-wheels/cpu/
# -> ERROR: Could not find a version that satisfies the requirement torch==2.1.2
#           (from versions: none)
```

**按 .whl 的完整 URL 装**，依赖解析才留在默认索引上：

```dockerfile
RUN pip install --no-cache-dir \
      "https://mirrors.aliyun.com/pytorch-wheels/cpu/torch-2.1.2%2Bcpu-cp310-cp310-linux_x86_64.whl" && \
    python -c "import torch,sys; v=torch.__version__; print('installed torch',v); \
               sys.exit(0 if v=='2.1.2+cpu' else 'expected 2.1.2+cpu, got '+v)"
```

**那个断言不是装饰。** `requirements.txt` 里写的是 `torch==2.1.2`，而 PEP 440 规定
不带 local 部分的 specifier 会匹配任意 local 版本，所以 `2.1.2+cpu` 能满足它、
后面的 `pip install -r` 会跳过 torch。**一旦这条不再成立，失败方式是静默地再去
下载 2.3 GB 的 CUDA 版**——所以要验版本，不要靠推断。

`blind_predict.py` 有 `--device {cuda,cpu}`，CPU torch 是**受支持的配置**，
不是降级妥协。要 GPU 的话把这一步换回 CUDA 构建即可，代价是上面的下载量。

**④ openbabel 必须走 pip，且必须补 X11 库**

openbabel 不是可选项：`ParaSurf/utils/features.py`、`ParaSurf/train/protein.py`、
`ParaSurf/utils/bio_data_featurizer.py` 三处都 `from openbabel import pybel`，
受体就是靠 `pybel.readfile('pdb', ...)` 读进来、算 SMARTS 理化特征的。绕不开。

上游写的是 `conda install -c conda-forge openbabel`。实测这一步静默 16 分钟未果。
**但先说清楚那个静默是什么**：`conda run` 会缓冲子进程输出、只在结束时统一吐出，
所以空日志是**健康求解的正常状态**，不是卡死的证据——别拿它当判活信号。
不等的理由是**成本**不是死锁：pip 这条路 2 秒装完（16.1 MB / 7.7 MB/s），
没必要为它付第二次解算。

```dockerfile
RUN conda run -n ParaSurf pip install --no-cache-dir openbabel-wheel==3.1.1.23
```

`openbabel-wheel` 是上游自己的 Python 绑定发行版，按 Python 版本和平台出预编译轮子，
3.1.1 正是 ParaSurf 代码对齐的分支（见 `bio_data_featurizer.py` 里 2.4.1 vs 3.1.1
那行注释）。清华源上 cp310/manylinux x86_64 轮子实测存在。

**但光装轮子会炸，报错还完全不指向真因。** openbabel-wheel 自带约 40 个格式插件
（`wlnformat` / `xtcformat` / `chemdrawcdx` / `groformat` / `nwchem` /
`pubchemjson` …），它们链接 X11 客户端库。精简的 CUDA 基础镜像里没有这些库，
于是每个插件往 stderr 打一句 `did not load properly` 就**静默从注册表消失**：

```
*** Open Babel Error  in openLib
    .../openbabel/3.1.0/wlnformat.so did not load properly.
  Error: libXrender.so.1: cannot open shared object file: No such file or directory
```

真正的症状落在别处——`openbabel/pybel.py:69` 那行
`broken = [(x, y.strip()) for x, y in broken]` 要把按 `" -- "` 切开的描述拆成两段，
插件缺了一部分之后有些描述不再带这个分隔符，于是
`from openbabel import pybel` 直接抛：

```
ValueError: not enough values to unpack (expected 2, got 1)
```

**报错指向 pybel，真因是缺 `libXrender.so.1`。** 所以必须单独补一层：

```dockerfile
RUN apt-get update && \
    apt-get install -y --no-install-recommends libxrender1 libxext6 libx11-6 libsm6 libice6 && \
    rm -rf /var/lib/apt/lists/*
```

这层要**单独成层、且放在 openbabel 之前而不是并进最上面那个 apt 层**——
并进去会让 torch(230 s) 和 requirements(178 s) 两层一起失效重跑。

装完要断言，而且**断言要查格式注册表、不只是查 import**：

```dockerfile
RUN conda run -n ParaSurf python -c "from openbabel import pybel; \
  m = next(pybel.readfile('pdb', '<repo>/test_blind_prediction/4N0Y_receptor_1.pdb')); \
  n = len(m.atoms); f = len(pybel.informats); \
  print('atoms=%d formats=%d pdb=%s' % (n, f, 'pdb' in pybel.informats)); \
  import sys; sys.exit(0 if (n > 1000 and f > 20 and 'pdb' in pybel.informats) \
    else 'UNHEALTHY atoms=%d formats=%d pdb=%s' % (n, f, 'pdb' in pybel.informats))"
```

跑 ParaSurf 自己的调用而不是只 `import pybel`；查注册表规模而不只看原子数——
上面那个失败恰好就是"注册表已经坏了但表面症状在别处"的类型。

**⑤ 基础镜像不要用上游的 `nvidia/cuda`**

这一条是**量出来的，不是看出来的**。保留 CUDA 基础层时构建全部 14 层都 DONE，
镜像 `docker images` 也能列出来（6.77 GB），但 `#18 unpacking` 这一步跑了 **45 分钟
没结束**，最终结果是：镜像能 `docker image inspect`（1.8 秒返回完整元数据），却
`docker run` 不出容器。

两个互相独立的原因说明这个基础层选错了：

1. ③ 装的是 **CPU 版 torch**，那 ~5 GB CUDA 运行时对 `--device cpu` 没有任何贡献；
2. 想用 GPU 的人**本来就用不了这个镜像**——必须先按 ③ 换回 CUDA 版 torch 构建，
   而那一步才需要 CUDA 基础层。

也就是说，对这份文件交付的默认配置而言，CUDA 基础层是纯粹的重量。改成
`FROM ubuntu:22.04`（两者都是 22.04，apt 镜像改写完全相同），镜像小一个量级。

要 GPU 路径就把 `FROM` 换回 `nvidia/cuda:11.8.0-cudnn8-devel-ubuntu22.04`
**并且**把 ③ 换回 CUDA torch 轮子，两处一起改，其余不用动。

**换基础层的连带后果：apt 必须分两段。** 裸 `ubuntu:22.04` **不带
`ca-certificates`**，apt 连 https 镜像都验不过：

```
No system certificates available. Try installing ca-certificates.
Certificate verification failed: The certificate is NOT trusted.  [IP: 101.6.15.130 443]
E: Unable to locate package wget
E: Unable to locate package git
E: Unable to locate package build-essential
```

清华源是 https，所以索引全拉不到、四个包一个都装不上。`nvidia/cuda` 基础镜像**恰好
带了** ca-certificates，所以换基础层之前一直没暴露——那是那个基础层唯一还在替我们
做的事。正解是先用 **http** 引导（apt 会警告但照做），装上证书再切回 **https**：

```dockerfile
RUN sed -i -e 's|http://archive.ubuntu.com/ubuntu|http://mirrors.tuna.tsinghua.edu.cn/ubuntu|g' \
           -e 's|http://security.ubuntu.com/ubuntu|http://mirrors.tuna.tsinghua.edu.cn/ubuntu|g' \
           /etc/apt/sources.list && \
    apt-get update && apt-get install -y --no-install-recommends ca-certificates && \
    sed -i 's|http://mirrors.tuna.tsinghua.edu.cn/ubuntu|https://mirrors.tuna.tsinghua.edu.cn/ubuntu|g' \
           /etc/apt/sources.list && \
    apt-get update && apt-get install -y --no-install-recommends wget git nano build-essential && \
    rm -rf /var/lib/apt/lists/*
```

后面的 4a（X11 库）可以直接 `apt-get update`，那时证书和 https 都已经就位。

**判"镜像好了没有"不要用 `docker images` 或 `docker image inspect`。** 这两个在
解包没完成时就正常返回了。唯一可靠的判据是**能不能起容器**：

```bash
docker run --rm --entrypoint echo parasurf:latest IMAGE_USABLE
```

另外两个和这条相关的坑：

- **杀掉 `docker build` 客户端不会取消解包。** BuildKit 的 export 已经提交给守护
  进程了，`kill` 掉客户端之后 `docker ps` 仍然长时间无响应。
- **判解包死活看 `docker_data.vhdx` 的 mtime，不要看文件大小。** 路径是
  `%LOCALAPPDATA%\Docker\wsl\disk\docker_data.vhdx`。它是 thick 预分配，解包是在
  已分配空间里**原地覆写**，实测 60 秒内大小 0 增长而 mtime 每分钟都在跳——
  用大小当指标会得出"卡死了"的错误结论。顺带一提，`wsl\main\ext4.vhdx` 是另一个
  对象（0.11 GB，长期不动），别搜错。

```bash
cp "${PLUGIN_DIR}/skills/protforge-parasurf/references/Dockerfile.protforge" ./Dockerfile.protforge
mkdir -p parasurf-build && cd parasurf-build
docker build -t parasurf:latest -f ../Dockerfile.protforge .
```

本插件**不提供**预构建 `protforge-parasurf` 镜像——镜像带 CUDA 基础层且体积不小，
是否预构建应由部署方决定。构建完成后**先做冒烟测试**再提交真实任务。

**长构建不要挂在交互任务上。** 构建超时被杀会留下"日志断在半路、镜像不存在"的
现场，看起来像网络卡死。正确做法是脱离任务超时独立运行，日志落盘：

```bash
docker build --progress=plain -t parasurf:latest -f Dockerfile.protforge . \
  > build.out.log 2> build.err.log &
```

**每一类包单独一层。** 这样重跑只重做没完成的那一步，而且每一步在日志里看得见——
合并成一条 `RUN` 时，pip 在非 TTY 下不输出进度，一条日志能静默几十分钟，
你分不清是在下载、在解包、还是已经死了。



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
