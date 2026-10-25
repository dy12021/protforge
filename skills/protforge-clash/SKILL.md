---
name: protforge-clash
description: "Detect and repair steric clashes in a protein structure, plus quick geometry checks (chain centroid distances, chain RMSD). Uses a cKDTree neighbor index, so it is O(n log n) instead of the O(n^2) all-pairs loop. Trigger: When the user asks to check a structure for clashes / steric overlaps / bad contacts, wants to repair overlapping atoms, wants the geometry of a complex checked (interface distance, RMSD between chains), or when a structure has just been built and needs a sanity check before delivery. Prefer this over writing an all-pairs distance loop yourself."
---

# Clash — 碰撞检测与几何校验

**要查碰撞就调这个工具，不要自己写两两比较的循环。**

## 为什么

2026-10-24 真实事故：agent 自己写了个「原子碰撞消解」，
是 `for i in range(n): for j in range(i+1, n): np.linalg.norm(...)`，
n = 6126 个原子 × 80 轮 = **15 亿次 norm 调用**，**跑了 4 小时 42 分**，
把那一行拖垮，还烧掉了整批的机时。

「哪些原子挨得近」这个问题用空间索引是 **O(n log n)**：
`scipy.spatial.cKDTree.query_pairs` 在 C 里做，几千个原子是**毫秒级**。
**两两比较是 O(n²)，不要手写。**

## 命令

```bash
bash "${PLUGIN_DIR}/skills/protforge-clash/scripts/clash.sh" "$pdb_path" "$job_name" "$mode" "$threshold"
```

- `$pdb_path` — 输入结构（绝对路径，或 `inputs/` 下的文件名）（required）
- `$job_name` — 任务名，默认 `clash`
- `$mode` — `report`（只报告，默认）或 `repair`（推开碰撞原子后另存）
- `$threshold` — 碰撞距离阈值（埃），默认 `2.0`

## 两种用法

**只报告**（先看有没有问题，别急着改）：

```bash
bash "${PLUGIN_DIR}/skills/protforge-clash/scripts/clash.sh" complex.pdb myjob report 2.0
```

**修**（把侧链上的碰撞推开；**主链不动**）：

```bash
bash "${PLUGIN_DIR}/skills/protforge-clash/scripts/clash.sh" complex.pdb myjob repair 2.0
```

`repair` 会把修复后的结构写成 `<job>_clash/<job>_repaired.pdb`，并报告修完还剩多少碰撞。

## 读结果

- `PROTFORGE_OUTPUT_DIR` — 输出目录
- `PROTFORGE_CLASHES` — 碰撞对数量
- `<job>_clash/clash_report.json` — 完整报告：
  - `clashes[]`：每一对的链/残基/原子名与距离（**从近到远排**）
  - `chain_centroid_distances`：链与链的质心距离（**看界面是否靠得住**）
  - `n_clashes_after`：修完还剩多少（`repair` 模式）

## 几何检查（顺带）

`clash.py` 还支持直接算两条链的 RMSD（Kabsch 叠合）：

```bash
"$PROTFORGE_PYTHON" "${PLUGIN_DIR}/skills/protforge-clash/scripts/clash.py" \
  --input complex.pdb --rmsd A:B --rmsd-target ref.pdb
```

## 注意

1. **只算重原子**（氢原子不参与碰撞判定）。
2. **同残基内、相邻残基间的原子对不算碰撞**——那些是共价键本来就该挨着的；
   算成碰撞的话，`repair` 会**把共价键推开**。
3. `repair` 默认**只动侧链**（不动 N/CA/C/O）：主链是骨架的锚，推它会把整个残基拽歪。
   真要动主链，说明这个碰撞本来就该用别的工具（重新设计侧链）解决。
4. **报告里距离很短的成对原子，先看是不是金属配位或共价连接**——它们可能是真实结构，
   不是碰撞。

## 和别的工具怎么搭

- 侧链重建完（PDBFixer / ProteinMPNN 之后）→ 跑一次 `report` 确认干净；
- 三元复合物组装完 → 跑一次拿 `chain_centroid_distances` 和 RMSD；
- 碰撞很多且集中在 CDR → **改设计**（换种子/改约束），别指望 `repair` 收拾。
