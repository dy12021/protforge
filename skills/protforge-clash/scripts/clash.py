"""碰撞检测与几何校验：用 **cKDTree** 找近距离原子对。

为什么要有这个工具
------------------
2026-10-24 真实事故：agent 自己写了个「原子碰撞消解」，是
``for i in range(n): for j in range(i+1, n): np.linalg.norm(...)``，
n = 6126 个原子 × 80 轮 = **15 亿次 norm 调用**，跑了 **4 小时 42 分**，
把那一行拖垮，还烧掉了整批的机时。

**两两比较是 O(n²)，而「哪些原子挨得近」这个问题用空间索引是 O(n log n)。**
`scipy.spatial.cKDTree.query_pairs` 在 C 里做这件事，几千个原子是**毫秒级**。

所以：**要查碰撞就调这个工具，不要自己写循环。**

用法::

    python clash.py --input a.pdb --mode report
    python clash.py --input a.pdb --mode repair --output out.pdb
    python clash.py --input a.pdb --rmsd A:B --rmsd-target b.pdb
"""
from __future__ import annotations

import argparse
import json
import os
import sys

import numpy as np
from scipy.spatial import cKDTree

import gemmi


# ---------------------------------------------------------------- 读结构

def read_atoms(path: str):
    """读结构，返回 (structure, atoms)。**只取重原子**（氢原子不参与碰撞判定）。"""
    st = gemmi.read_structure(path)
    st.setup_entities()
    rows = []
    for model in st:
        for chain in model:
            for res in chain:
                for a in res:
                    if a.element == "H":
                        continue
                    rows.append({
                        "chain": chain.name,
                        "seq": int(res.seqid.num),
                        "res": res.name,
                        "atom": a.name,
                        "pos": np.array([a.pos.x, a.pos.y, a.pos.z], dtype=float),
                        "el": a.element,
                        "atom_obj": a,
                    })
        break                      # 只要第一个 model
    return st, rows


def bonded_or_same(a: dict, b: dict) -> bool:
    """这两个原子是不是「本来就该挨着」。

    判据：同一个残基（键内），或者同一条链的相邻残基（肽键 C-N）。
    这两类不是碰撞——把它们算成碰撞，修结构时会**把共价键推开**。
    """
    if a["chain"] == b["chain"] and a["seq"] == b["seq"]:
        return True
    if a["chain"] == b["chain"] and abs(a["seq"] - b["seq"]) == 1:
        return True
    return False


# ---------------------------------------------------------------- 碰撞

def find_clashes(atoms, threshold: float, same_residue: bool = True):
    """找出「非键合却靠得太近」的原子对。"""
    if not atoms:
        return []
    pos = np.array([a["pos"] for a in atoms])
    tree = cKDTree(pos)
    pairs = tree.query_pairs(threshold)        # ← C 实现，O(n log n)
    out = []
    for i, j in pairs:
        a, b = atoms[i], atoms[j]
        if not same_residue and a["chain"] == b["chain"] and a["seq"] == b["seq"]:
            continue
        if bonded_or_same(a, b):
            continue
        d = float(np.linalg.norm(a["pos"] - b["pos"]))
        out.append((i, j, d))
    out.sort(key=lambda t: t[2])
    return out


def repair(atoms, clashes, threshold: float, movable_only: bool = True):
    """把碰撞的原子沿连线推开。

    **默认只动侧链**（不动主链原子）：主链是骨架的锚，推它会把整个残基拽歪；
    真要动主链，说明这个碰撞本来就该用别的工具（重新设计侧链）解决。

    返回 ``(moved, unfixable)``：
    - ``moved`` 实际推开的接触数；
    - ``unfixable`` **两个原子都是主链**的碰撞数——这些**修不了**，
      必须写进报告，否则调用方会以为「修完了」而其实一处没动。
    """
    BACKBONE = {"N", "CA", "C", "O", "OXT"}
    moved = 0
    unfixable = 0
    # 多迭代几轮：一次推开可能制造新的接触
    for _ in range(20):
        cur = find_clashes(atoms, threshold)
        if not cur:
            break
        progressed = False
        for i, j, _d in cur:
            a, b = atoms[i], atoms[j]
            am = a["atom"] not in BACKBONE
            bm = b["atom"] not in BACKBONE
            if movable_only and not (am or bm):
                unfixable += 1
                continue
            va = a["pos"] - b["pos"]
            n = float(np.linalg.norm(va))
            if n < 1e-6:
                continue
            va = va / n * (threshold - n)
            if am and bm:
                a["pos"] += va / 2.0
                b["pos"] -= va / 2.0
            elif am:
                a["pos"] += va
            elif bm:
                b["pos"] -= va
            else:
                continue
            moved += 1
            progressed = True
        if not progressed and unfixable:
            # 全是主链碰撞，推不动 —— 再迭代也是白转
            break
    return moved, unfixable


def chain_centroids(atoms):
    out = {}
    for a in atoms:
        out.setdefault(a["chain"], []).append(a["pos"])
    return {k: np.mean(np.array(v), axis=0) for k, v in out.items()}


def kabsch_rmsd(p: np.ndarray, q: np.ndarray) -> float:
    """两组对应点的最小 RMSD（Kabsch）。"""
    if p.shape != q.shape or p.shape[0] < 3:
        return float("nan")
    pc, qc = p.mean(0), q.mean(0)
    P, Q = p - pc, q - qc
    H = P.T @ Q
    U, S, Vt = np.linalg.svd(H)
    d = np.sign(np.linalg.det(Vt.T @ U.T))
    D = np.diag([1.0, 1.0, d])
    R = Vt.T @ D @ U.T
    P2 = (R @ P.T).T
    return float(np.sqrt(((P2 - Q) ** 2).sum(axis=1).mean()))


# ---------------------------------------------------------------- main

def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description="clash detection / geometry check")
    ap.add_argument("--input", required=True, help="input PDB/mmCIF")
    ap.add_argument("--output", default="", help="repaired structure (repair mode)")
    ap.add_argument("--mode", default="report", choices=["report", "repair"])
    ap.add_argument("--threshold", type=float, default=2.0,
                    help="clash distance threshold (Angstrom), default 2.0")
    ap.add_argument("--include-intra-residue", action="store_true",
                    help="also count same-residue pairs as clashes")
    ap.add_argument("--move-backbone", action="store_true",
                    help="allow moving backbone atoms during repair")
    ap.add_argument("--rmsd", default="",
                    help="chain pair for RMSD, e.g. A:B")
    ap.add_argument("--rmsd-target", default="", help="reference structure for RMSD")
    ap.add_argument("--json", default="", help="write the report as JSON")
    ap.add_argument("--max-list", type=int, default=50,
                    help="how many clashes to list in the text report")
    args = ap.parse_args(argv)

    if not os.path.isfile(args.input):
        print(f"input not found: {args.input}", file=sys.stderr)
        return 2

    st, atoms = read_atoms(args.input)
    if not atoms:
        print("no heavy atoms found", file=sys.stderr)
        return 2

    clashes = find_clashes(atoms, args.threshold,
                           same_residue=args.include_intra_residue)
    report = {
        "input": os.path.abspath(args.input),
        "n_atoms": len(atoms),
        "threshold": args.threshold,
        "n_clashes": len(clashes),
        "clashes": [
            {
                "chain_a": atoms[i]["chain"], "res_a": atoms[i]["res"],
                "atom_a": atoms[i]["atom"],
                "chain_b": atoms[j]["chain"], "res_b": atoms[j]["res"],
                "atom_b": atoms[j]["atom"],
                "distance": round(d, 3),
            }
            for i, j, d in clashes[: args.max_list]
        ],
    }

    cent = chain_centroids(atoms)
    report["chain_centroid_distances"] = {
        f"{a}|{b}": round(float(np.linalg.norm(cent[a] - cent[b])), 3)
        for a in sorted(cent) for b in sorted(cent) if a < b
    }

    if args.rmsd and args.rmsd_target:
        try:
            ca, cb = args.rmsd.split(":")
            p = np.array([a["pos"] for a in atoms if a["chain"] == ca])
            q = np.array([a["pos"] for a in atoms if a["chain"] == cb])
            n = min(len(p), len(q))
            report["rmsd_chain_pair"] = args.rmsd
            report["rmsd_approx"] = round(kabsch_rmsd(p[:n], q[:n]), 4)
        except Exception as exc:                      # noqa: BLE001
            report["rmsd_error"] = str(exc)

    if args.mode == "repair":
        moved, unfixable = repair(atoms, clashes, args.threshold,
                                  movable_only=not args.move_backbone)
        report["moved_contacts"] = moved
        report["unfixable_backbone_clashes"] = unfixable
        after = find_clashes(atoms, args.threshold,
                             same_residue=args.include_intra_residue)
        report["n_clashes_after"] = len(after)
        if args.output:
            out = args.output
            if not os.path.isabs(out):
                out = os.path.abspath(out)
            os.makedirs(os.path.dirname(out) or ".", exist_ok=True)
            # 把算完的坐标写回原结构
            for a in atoms:
                a["atom_obj"].pos = gemmi.Position(*[float(x) for x in a["pos"]])
            st.write_pdb(out)
            report["output"] = out

    if args.json:
        with open(args.json, "w", encoding="utf-8") as fh:
            json.dump(report, fh, ensure_ascii=False, indent=1)

    print(f"atoms: {report['n_atoms']}  threshold: {args.threshold} A")
    print(f"clashes: {report['n_clashes']}")
    for c in report["clashes"][:20]:
        print(f"  {c['chain_a']}{c['res_a']}:{c['atom_a']} -- "
              f"{c['chain_b']}{c['res_b']}:{c['atom_b']}  {c['distance']} A")
    if args.mode == "repair":
        print(f"moved contacts: {report.get('moved_contacts')}  "
              f"clashes after: {report.get('n_clashes_after')}  "
              f"backbone-only (not movable): "
              f"{report.get('unfixable_backbone_clashes')}")
    if "rmsd_approx" in report:
        print(f"RMSD({report['rmsd_chain_pair']}) = {report['rmsd_approx']} A")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
