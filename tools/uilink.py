#!/usr/bin/env python3
"""uilink — build the UI bank LINK TABLE (src/installer/converters/ui_links.tsv). Dev only.

The installer dumps every shape and bitmap of a few SWFs into content/baseui/bethassets/<source>/.
A character id differs between game versions (and ids get REUSED for unrelated art), so the table
links them by APPEARANCE: one id column per exe product version. The installer names each file by
the first column's id, or <kind>_x<own id>.dds when this version has no link for it.

Workflow (the installs can live on different machines):
  1. On LE:  python3 uilink.py gen   <LE bethassets dir> <table.tsv> 1.9.32.0
     → one row per bank file: its id + a pixel FINGERPRINT (size, colour, silhouette dhash).
  2. Per other version:  python3 uilink.py match <bethassets dir> <table.tsv> <version>
     → fills that version's column from its unlinked (_x) files, by fingerprint, one-to-one.
     Review the UNMATCHED report, then commit and reinstall.

Pure stdlib (no numpy/PIL) so it runs anywhere. DDS here is always 128-byte header + w*h*4 bytes RGBA.
"""

import os
import sys
import struct
import glob

SOURCES = ("startmenu", "creditsmenu", "loadingmenu", "hudmenu")
HAMMING_ACCEPT = 18  # max silhouette-dhash Hamming distance to call it the same art


# ---- DDS + fingerprint -------------------------------------------------------

def read_dds(path):
    """Return (w, h, rgba_bytes) for an uncompressed-RGBA DDS, or None."""
    with open(path, "rb") as f:
        data = f.read()
    if len(data) < 128 or data[:4] != b"DDS ":
        return None
    h = struct.unpack_from("<I", data, 12)[0]
    w = struct.unpack_from("<I", data, 16)[0]
    px = data[128:128 + w * h * 4]
    if len(px) != w * h * 4:
        return None
    return w, h, px


def fingerprint(w, h, px):
    """(coverage, (r,g,b), dhash64) — colour of the ink + a silhouette hash of the alpha channel."""
    # Average colour over inked (alpha>16) pixels; mean coverage.
    rs = gs = bs = n = 0
    acov = 0
    for i in range(0, len(px), 4):
        a = px[i + 3]
        acov += a
        if a > 16:
            rs += px[i]; gs += px[i + 1]; bs += px[i + 2]; n += 1
    cov = acov / (255.0 * w * h)
    avg = (rs // n, gs // n, bs // n) if n else (0, 0, 0)

    # dhash of the ALPHA channel (the silhouette — stable across editions regardless of fill colour):
    # box-downsample alpha to 9x8, then bit = left>right per row → 64 bits.
    GW, GH = 9, 8
    grid = [0] * (GW * GH)
    for gy in range(GH):
        y0, y1 = gy * h // GH, (gy + 1) * h // GH
        y1 = max(y1, y0 + 1)
        for gx in range(GW):
            x0, x1 = gx * w // GW, (gx + 1) * w // GW
            x1 = max(x1, x0 + 1)
            s = c = 0
            for yy in range(y0, y1):
                base = (yy * w + x0) * 4 + 3
                for k in range(x1 - x0):
                    s += px[base + k * 4]; c += 1
            grid[gy * GW + gx] = s / c if c else 0
    bits = 0
    for gy in range(GH):
        for gx in range(GW - 1):
            bits = (bits << 1) | (1 if grid[gy * GW + gx] > grid[gy * GW + gx + 1] else 0)
    return cov, avg, bits


def hamming(a, b):
    return bin(a ^ b).count("1")


# ---- asset enumeration -------------------------------------------------------

def scan(bethassets, unlinked_only=False):
    """List (source, kind, id, path) for every bank file under bethassets; id is the file's own for _x."""
    out = []
    for src in SOURCES:
        d = os.path.join(bethassets, src)
        if not os.path.isdir(d):
            continue
        for kind in ("shape", "bitmap"):
            for p in sorted(glob.glob(os.path.join(d, kind + "_*.dds"))):
                stem = os.path.basename(p)[len(kind) + 1:-4]
                unlinked = stem.startswith("x")
                stem = stem.lstrip("x")
                if stem.isdigit() and (unlinked or not unlinked_only):
                    out.append((src, kind, int(stem), p))
    return out


FP_COLS = ("w", "h", "cov", "rgb", "dhash")


def gen(bethassets, out_tsv, version):
    rows = []
    for src, kind, cid, path in scan(bethassets):
        dds = read_dds(path)
        if not dds:
            print(f"skip (unreadable): {path}", file=sys.stderr)
            continue
        w, h, px = dds
        cov, (r, g, b), dh = fingerprint(w, h, px)
        rows.append({"source": src, "kind": kind, version: cid, "w": w, "h": h,
                     "cov": f"{cov:.3f}", "rgb": f"{r:02x}{g:02x}{b:02x}", "dhash": f"{dh:016x}"})
    write_tsv(out_tsv, ["source", "kind", version, *FP_COLS], rows)
    print(f"gen: {len(rows)} assets → {out_tsv} (run `match` per other version)")


def match(bethassets, tsv, version):
    cols, all_rows = read_tsv(tsv)
    if version not in cols:
        cols.insert(cols.index("w"), version)
    rows = [r for r in all_rows if int(r.get(version) or 0) == 0]  # the rows this version still lacks
    se = scan(bethassets, unlinked_only=True)
    # Fingerprint every unlinked file once, bucketed by (source, kind).
    se_fp = {}
    for src, kind, cid, path in se:
        dds = read_dds(path)
        if not dds:
            continue
        w, h, px = dds
        cov, avg, dh = fingerprint(w, h, px)
        se_fp.setdefault((src, kind), []).append(dict(id=cid, w=w, h=h, cov=cov, rgb=avg, dhash=dh))

    matched = unmatched = 0
    for key, group in bucket(rows).items():
        cands = list(se_fp.get(key, []))
        # Score every row×file pair, then assign greedily 1:1 (best global pairs first).
        pairs = []
        for li, lr in enumerate(group):
            for si, sc in enumerate(cands):
                d = score(lr, sc)
                if d is not None:
                    pairs.append((d, li, si))
        pairs.sort()
        lused, sused = set(), set()
        for d, li, si in pairs:
            if li in lused or si in sused:
                continue
            group[li][version] = cands[si]["id"]
            lused.add(li); sused.add(si); matched += 1
        for li, lr in enumerate(group):
            if li not in lused:
                unmatched += 1
                print(f"UNMATCHED  {lr['source']}/{lr['kind']}_{lr[cols[2]]}  "
                      f"({lr['w']}x{lr['h']} #{lr['rgb']})", file=sys.stderr)
    write_tsv(tsv, cols, all_rows)
    print(f"match: {matched} linked, {unmatched} unmatched → {tsv}")


def score(lr, sc):
    """Lower is better; None = fails a hard gate (not the same art)."""
    lw, lh = int(lr["w"]), int(lr["h"])
    if sc["w"] <= 0 or sc["h"] <= 0 or lw <= 0 or lh <= 0:
        return None
    # Aspect gate (silhouettes keep their proportions across editions).
    la, sa = lw / lh, sc["w"] / sc["h"]
    if abs(la - sa) / la > 0.25:
        return None
    ham = hamming(int(lr["dhash"], 16), sc["dhash"])
    if ham > HAMMING_ACCEPT:
        return None
    lr_rgb = (int(lr["rgb"][0:2], 16), int(lr["rgb"][2:4], 16), int(lr["rgb"][4:6], 16))
    cdiff = sum(abs(a - b) for a, b in zip(lr_rgb, sc["rgb"]))
    sdiff = abs(lw - sc["w"]) + abs(lh - sc["h"])
    return ham * 100 + cdiff + sdiff * 0.5


# ---- tsv io ------------------------------------------------------------------

def bucket(rows):
    b = {}
    for r in rows:
        b.setdefault((r["source"], r["kind"]), []).append(r)
    return b


def write_tsv(path, cols, rows):
    with open(path, "w") as f:
        f.write("\t".join(cols) + "\n")
        for r in rows:
            f.write("\t".join(str(r.get(c, 0)) for c in cols) + "\n")


def read_tsv(path):
    with open(path) as f:
        lines = [ln.rstrip("\n") for ln in f if ln.strip()]
    hdr = lines[0].split("\t")
    return hdr, [dict(zip(hdr, ln.split("\t"))) for ln in lines[1:]]


# ---- cli ---------------------------------------------------------------------

if __name__ == "__main__":
    a = sys.argv[1:]
    if len(a) == 4 and a[0] == "gen":
        gen(a[1], a[2], a[3])
    elif len(a) == 4 and a[0] == "match":
        match(a[1], a[2], a[3])
    else:
        print(__doc__)
        print("usage:\n  uilink.py gen   <bethassets dir> <table.tsv> <version>\n"
              "  uilink.py match <bethassets dir> <table.tsv> <version>", file=sys.stderr)
        sys.exit(2)
