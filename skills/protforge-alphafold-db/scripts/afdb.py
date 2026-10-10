#!/usr/bin/env python
"""afdb.py - Query the public AlphaFold Protein Structure Database and download models.

AlphaFold DB (Google DeepMind + EMBL-EBI): https://alphafold.ebi.ac.uk
API: GET https://alphafold.ebi.ac.uk/api/prediction/<UniProt accession or AF entry id>

Stdlib only - no pip installs. Prints a summary plus PROTFORGE_* markers for chaining
with the other protforge skills.
"""
import argparse
import json
import os
import sys
import urllib.error
import urllib.request

if sys.platform == "win32":
    for _s in (sys.stdout, sys.stderr):
        try:
            _s.reconfigure(encoding="utf-8", errors="replace")
        except Exception:
            pass

API = "https://alphafold.ebi.ac.uk/api/prediction/{}"
ENTRY_PAGE = "https://alphafold.ebi.ac.uk/entry/{}"
UA = {"User-Agent": "protforge-alphafold-db/1.0 (alphafold.ebi.ac.uk api client)"}

FILE_KEYS = {
    "cif": "cifUrl",
    "pdb": "pdbUrl",
    "bcif": "bcifUrl",
    "pae": "paeDocUrl",
    "pae-img": "paeImageUrl",
    "plddt": "plddtDocUrl",
    "msa": "msaUrl",
    "am": "amAnnotationsUrl",
}


def fail(msg):
    print("PROTFORGE_STATUS: FAIL " + msg)
    sys.exit(1)


def http_json(url, timeout=60):
    req = urllib.request.Request(url, headers=UA)
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return json.loads(r.read().decode("utf-8"))


def download(url, dest, timeout=300):
    req = urllib.request.Request(url, headers=UA)
    with urllib.request.urlopen(req, timeout=timeout) as r, open(dest, "wb") as f:
        while True:
            chunk = r.read(1 << 20)
            if not chunk:
                break
            f.write(chunk)


def default_out_dir(acc):
    protforge_data = os.environ.get("PROTFORGE_DATA")
    if protforge_data:
        return os.path.join(protforge_data, "outputs", acc + "_afdb")
    protforge_home = os.environ.get("PROTFORGE_HOME")
    if protforge_home:
        return os.path.join(protforge_home, "data", "outputs", acc + "_afdb")
    return os.path.join(os.getcwd(), "afdb_outputs", acc + "_afdb")


def summarize(entry):
    acc = entry.get("uniprotAccession") or entry.get("entryId") or "?"
    eid = entry.get("entryId", "?")
    gene = entry.get("gene") or "-"
    uid = entry.get("uniprotId") or "-"
    org = entry.get("organismScientificName") or "-"
    length = entry.get("uniprotEnd") or entry.get("sequenceEnd") or "?"
    plddt = entry.get("globalMetricValue")
    ver = entry.get("latestVersion", "?")
    print("[protforge-afdb] {}  {} / {}  {}  {} aa".format(eid, gene, uid, org, length))
    if plddt is not None:
        fv = entry.get("fractionPlddtVeryHigh", 0) * 100
        fc = entry.get("fractionPlddtConfident", 0) * 100
        fl = entry.get("fractionPlddtLow", 0) * 100
        fvl = entry.get("fractionPlddtVeryLow", 0) * 100
        print("[protforge-afdb] mean pLDDT {:.2f}  (very high {:.1f}% | confident {:.1f}% | "
              "low {:.1f}% | very low {:.1f}%)  model v{}".format(plddt, fv, fc, fl, fvl, ver))
    print("[protforge-afdb] entry page: " + ENTRY_PAGE.format(acc))
    return acc


def main():
    ap = argparse.ArgumentParser(
        description="Query AlphaFold DB and download pre-computed predicted models.")
    ap.add_argument("accession",
                    help="UniProt accession (e.g. P69905) or AF DB entry id (AF-P69905-F1)")
    ap.add_argument("--out", help="output directory (default: $PROTFORGE_DATA/outputs/<ACC>_afdb)")
    ap.add_argument("--files", default="cif,pdb,pae,plddt",
                    help="comma list from: " + ",".join(FILE_KEYS) + " (default cif,pdb,pae,plddt)")
    ap.add_argument("--query-only", action="store_true",
                    help="print summary only, do not download")
    args = ap.parse_args()

    acc = args.accession.strip()
    wanted = [w.strip().lower() for w in args.files.split(",") if w.strip()]
    bad = [w for w in wanted if w not in FILE_KEYS]
    if bad:
        fail("unknown --files keys: {} (choose from {})".format(",".join(bad), ",".join(FILE_KEYS)))

    try:
        data = http_json(API.format(acc))
    except urllib.error.HTTPError as e:
        if e.code == 404:
            fail("{}: no public AlphaFold DB entry (valid accession, but no pre-computed "
                 "model). For a new prediction use protforge-alphafold3.".format(acc))
        body = ""
        try:
            body = e.read().decode("utf-8", "replace")[:300]
        except Exception:
            pass
        fail("HTTP {} for {}: {}".format(e.code, acc, body))
    except (urllib.error.URLError, TimeoutError, OSError) as e:
        fail("network error for {}: {}".format(acc, e))

    if isinstance(data, dict) and data.get("error"):
        fail("{}: {}".format(acc, data["error"]))
    entries = data if isinstance(data, list) else [data]
    if not entries:
        fail("{}: no public AlphaFold DB entry (valid accession, but no pre-computed model). "
             "For a new prediction use protforge-alphafold3.".format(acc))

    first_acc = entries[0].get("uniprotAccession") or acc
    out_dir = args.out or default_out_dir(first_acc)
    first_cif = None

    for i, entry in enumerate(entries):
        e_acc = summarize(entry)
        if args.query_only:
            continue
        dest_dir = out_dir if len(entries) == 1 else os.path.join(out_dir, entry.get("entryId", str(i)))
        os.makedirs(dest_dir, exist_ok=True)
        for key in wanted:
            url = entry.get(FILE_KEYS[key])
            if not url:
                print("[protforge-afdb] skip {}: not available for this entry".format(key))
                continue
            dest = os.path.join(dest_dir, url.rsplit("/", 1)[-1])
            try:
                download(url, dest)
            except (urllib.error.URLError, TimeoutError, OSError) as e:
                fail("download failed for {}: {}".format(url, e))
            size = os.path.getsize(dest)
            print("[protforge-afdb] saved {:>10,d} B  {}".format(size, dest))
            if key == "cif" and first_cif is None:
                first_cif = dest

    if first_cif:
        print("PROTFORGE_CIF: " + first_cif)
    print("PROTFORGE_STATUS: OK")


if __name__ == "__main__":
    main()
