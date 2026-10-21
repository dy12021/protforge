#!/usr/bin/env python3
"""Reduce a PDB to exactly the two antibody chains ParaSurf will accept.

Upstream blind_predict.py validates its input with antibody_input_recognition(),
which accepts EXACTLY 2 chains and exits 1 otherwise. ProtForge's delivered
antibody files are ternary complexes (antigen + VH + VL), so the Fv has to be
carved out first -- otherwise ParaSurf rejects the file with a message that
reads like a broken installation.

Pure text, no Biopython: the image ships Biopython, but the host may not, and
chain ids are unambiguous in a PDB ATOM record (column 22).

Usage:
    python extract_antibody_chains.py <input.pdb> <output.pdb>

Prints PROTFORGE_PARASURF_CHAIN_* lines so the caller can report exactly
which chains were kept and which were dropped.
"""
import os
import shutil
import sys


def read_pdb(path):
    """Return (header_lines, {chain_id: [records]}, chain_order)."""
    header = []
    chains = {}
    order = []
    with open(path, "r", encoding="utf-8", errors="replace") as fh:
        for line in fh:
            if line.startswith(("ATOM", "HETATM")):
                cid = line[21]
                if cid not in chains:
                    chains[cid] = []
                    order.append(cid)
                chains[cid].append(line.rstrip("\n"))
            elif line.startswith(("TER", "END", "ENDMDL")):
                continue
            else:
                header.append(line.rstrip("\n"))
    return header, chains, order


def select_chains(chains, order):
    """Return (keep_list, reason). Prefer an explicit H/L pair."""
    if len(order) == 2:
        return list(order), "input already has exactly 2 chains"
    if len(order) < 2:
        raise SystemExit(
            "only %d chain(s) in the input; ParaSurf needs exactly 2" % len(order))
    upper = {c.upper(): c for c in order}
    if "H" in upper and "L" in upper:
        return [upper["H"], upper["L"]], "selected H+L (heavy/light chain ids)"
    ranked = sorted(order, key=lambda c: len(chains[c]), reverse=True)
    return ranked[:2], "selected the two largest chains by atom count"


def main():
    if len(sys.argv) != 3:
        raise SystemExit("usage: extract_antibody_chains.py <input.pdb> <output.pdb>")
    src, dst = sys.argv[1], sys.argv[2]

    header, chains, order = read_pdb(src)
    keep, reason = select_chains(chains, order)
    dropped = [c for c in order if c not in keep]

    print("PROTFORGE_PARASURF_CHAIN_INPUT_TOTAL: %d (%s)"
          % (len(order), ", ".join("%s=%d" % (c, len(chains[c])) for c in order)))
    if dropped:
        print("PROTFORGE_PARASURF_CHAIN_DROPPED: %s"
              % ", ".join("%s=%d" % (c, len(chains[c])) for c in dropped))
    print("PROTFORGE_PARASURF_CHAIN_SELECTED: %s" % ", ".join(keep))
    print("PROTFORGE_PARASURF_CHAIN_REASON: %s" % reason)

    out_dir = os.path.dirname(os.path.abspath(dst))
    if out_dir:
        os.makedirs(out_dir, exist_ok=True)

    if not dropped:
        # Already a 2-chain antibody: copy it byte for byte rather than
        # rewriting records that upstream would have to re-parse.
        shutil.copyfile(src, dst)
        print("PROTFORGE_PARASURF_CHAIN_OUTPUT: %d atoms in %d chains (copied verbatim)"
              % (sum(len(chains[c]) for c in keep), len(keep)))
        return

    lines = []
    lines.append("REMARK 900 PROTFORGE ParaSurf antibody-only extraction")
    lines.append("REMARK 900 source: %s" % src.replace("\\", "/"))
    lines.append("REMARK 900 kept chains: %s ; dropped: %s"
                 % (",".join(keep), ",".join(dropped) if dropped else "none"))
    for line in header:
        if line.startswith("REMARK"):
            continue
        lines.append(line)
    for cid in keep:
        lines.extend(chains[cid])
        lines.append("TER   %5d      %-3s  " % (9999, cid))
    lines.append("END")

    with open(dst, "w", encoding="utf-8", newline="\n") as fh:
        fh.write("\n".join(lines) + "\n")

    print("PROTFORGE_PARASURF_CHAIN_OUTPUT: %d atoms in %d chains"
          % (sum(len(chains[c]) for c in keep), len(keep)))


if __name__ == "__main__":
    main()
