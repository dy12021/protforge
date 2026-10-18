# 松弛与筛选：配方与失效特征

## 受限松弛配方

### 约束施加顺序（错误代价极高）

```python
sim.minimizeEnergy(...)                              # 先最小化
sim.context.setVelocitiesToTemperature(T, seed)      # 再设速度
sim.step(MD_STEPS)                                   # 最后跑 MD
```

速度设在最小化**之前**时，每一个设计都发散成 NaN。最小化不清零积分器的
thermostat 状态。改回顺序后 42/42 恢复正常。

### 种子

```python
seed = BASE ^ (crc32(该设计自身的坐标记录) & 0x7FFFFFFF)
```

- **不设种子**：每个构象是一次随机抽样，判据在设计上不可复现。
- **全局固定种子**：更糟。每条设计拿到**完全相同**的速度分配，约 7100 个原子
  同向运动，系统性不稳定。
- **按设计派生**：可复现，且各设计独立。

种子必须来自设计**内容**（排序后的 ATOM/HETATM 行），不要哈希整个文件——文件名
或头部文本的差异会让同一条设计落到不同种子上。这条踩过：两次「同一设计」的测量
用了不同暂存文件名，seed 不同，结果差 0.3 Å，一度被误判成流程缺陷。

### NaN 防护

NaN 只在写结构文件时抛出来，也就是**整轮跑完才失败**；批量脚本若在循环之后写盘，
这一批全丢。

```python
pre_md = sim.context.getState(getPositions=True).getPositions(asNumpy=True)
try:
    sim.context.setVelocitiesToTemperature(300*unit.kelvin, seed)
    sim.step(MD_STEPS)
    if not np.isfinite(final_positions).all():
        raise ValueError("non-finite coordinates")
except Exception:
    sim.context.setPositions(pre_md)   # 回退到最小化构象
    md_ok = False                      # 显式标注 no MD
```

MD 是精修不是测量。发散时保留最小化构象并标注，比丢掉整个设计好。

### 可复现性的真实精度：必须实测，不能从种子派生推断

GPU 归约不是逐位确定的。**实测**：同一份输入文件、同一颗速度种子，重建 3 次，
最小重原子距离散布 **0.24 Å**（捕获 2.97 / 2.80 / 3.04；检测 2.68 / 2.78 / 2.54）。
无种子时散布 0.2–0.4 Å。

**规则**：可复现性只能靠 `repro_check.py` 这类「同输入同种子重复 N 次」的脚本测出来，
**不能因为种子是内容派生的（`seed_base XOR CRC32(排序后 ATOM 行)`）就断言可复现**。
本技能早期版本写的是「可复现到 ~0.02 Å」，那是从种子派生方式**推出来的**，从没测过，
实测是错的——而它已经进了交付文件。

写交付时：说「固定种子下不可复现，N 次重复散布 X Å」，不要写「可复现」，
也不要写任何没测过的精度数字。

### 交付构象必须是它自己那份分布里的一个成员

交付的 PDB 与记录的构象分布**必须出自同一批松弛**。两批抽样会让交付值落到
记录区间之外（本例：交付 2.94 Å vs 记录 2.73–2.88 Å），交付自相矛盾，
比数值难看严重得多。

选交付构象的规则要在**测量前**定死：

| 规则 | 后果 |
|---|---|
| 交付调度器随机产出的那一个 | 等于抽样，会抽到最差构象（本例 2.51 Å 且触及埋藏面残基 50） |
| 4 个种子按最小距离排序取**中位数** | 预先声明、不朝判据凑；分布与交付同批 |

自检：`delivered_value in recorded_values`。「落在区间内」是不够的——
本例中这个较弱的检查曾经放过一次真正的不一致。

## 多种子判据

任何距离类判据都必须多种子评估：

```python
vals = [measure(seed_base=BASE + 1000*k) for k in range(n)]
report = {"min": min(vals), "median": median(vals), "max": max(vals),
          "clears": f"{sum(clears)}/{n}"}
```

**1/4 构象过线 ≠ 过线。** 把结论记成 shortfall，不要引用那个好的抽样。

判据结论字段用两种，不要混：

- `FAIL`：声明与数据矛盾 → 改流水线（重算值 ≠ 记录值、序列与坐标不符）
- `GAP`：真实局限 → 披露（未达阈值、某构象触及埋藏面）

### 判据检查要验「数据一致性」，不要验字符串相等

```python
# 错：verdict 换个正确说法就判 FAIL，而交付本身是对的
ck(verdict == "not met on most conformers", ...)

# 对：从逐种子数据推出应有结论，再比对
n_clear = sum(1 for v, p in zip(vals, pairs) if v >= 3.0 and p == 0)
ck(verdict == ("ROBUSTLY MET" if n_clear == n else "NOT ROBUSTLY MET"), ...)
```

判据未达本身走 `GAP`，不走 `FAIL`；`FAIL` 留给「verdict 与自己的数据矛盾」。

## 按几何排序候选

骨架被刚体对接冻结 ⇒ **哪些 CDR 位点贴着抗原是位姿属性、与设计无关**；只有
贴上去的侧链因设计而异。

```python
contact_pos = {ch: [i for i in CDR[ch]
                    if min_dist(pose_backbone[ch][i], antigen) < 8.0]}
bulk = sum(SC_HEAVY[design[ch][i-1]] for ch in contact_pos for i in contact_pos[ch])
# 按 bulk 升序送去做松弛
```

**不要按模型序列分数排序。** 实测：检测位姿下，MPNN 分数前 6 名里有 2 名是
128 条里接触面最臃肿的，6/6 全部未过线；换成体积排序后 79 条中 16 条过线。

## 本管线中已验证废弃的路线

- **RFdiffusion 无热点引导势**：本机构建里 `ppi.hotspot_res` 在
  `potentials/manager.py` 算出后从未被使用，于是整条抗体链被重摆，界面 BSA 只有
  170–480 Å²。用它之前先确认热点势真的接进去了（见 `protforge-rfdiffusion`）。
- **IgFold 重新预测 Fv 结构**：手上已有支架晶体结构时是纯粹的信息损失。
- **DiffDock 类 Ab-Ag 对接**：成功率低，产出应是多个候选位姿而不是判决。
- **MM-GBSA / PRODIGY 当排序指标**：绝对值对 Ab-Ag 不可靠；两个候选界面差
  0.2 Å 量级时，方法噪声远大于信号，会制造虚假精度感。
