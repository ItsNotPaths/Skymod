# Writes src/installer/converters/tickrates.tsv: an OnTick rate for each split class (ws.md S7).
# Usage: tickrates.py <installed scripts dir> <props.tsv> > tickrates.tsv
# props.tsv is `esmdump <plugin> --vmad-props` over every plugin. Hand patches set their own rate.
import collections, os, re, sys

WAIT = re.compile(r'self\.vars\["[^"]*\.t"\] = (.*?)(?: \+ __late)?$', re.M)
LIT = re.compile(r'^(?:rt\.cast\()?(-?[0-9.]+)(?:, "float"\))?$')
CAST = re.compile(r'^rt\.cast\((.*), "float"\)$')
VAR = re.compile(r'^self\.vars\["([^"]+)"\]$')
CLASS = re.compile(r'rt\.class\("([^"]+)", "([^"]*)"\)')
DEFAULT = re.compile(r'\["([^"]+)"\] = \{ type = "(?:Float|Int)", default = (-?[0-9.]+|nil) \}')
AUTOPROP = re.compile(r'__autoprop\["([^"]+)"\] = "([^"]+)"')
HZ = [10, 20, 30, 60]

def hz(waits):
    # the slowest rate at which no wait fires more than one 60 Hz tick late
    for h in HZ:
        if all((-(-w * h // 1) - w * h) / h <= 1 / 60 + 1e-9 for w in waits): return h
    return 60

def source(text, e):
    # a wait on a temp reads the temp's last assignment before the wait
    m = CAST.match(e)
    if m: e = m.group(1)
    if e.startswith("__temp"):
        defs = re.findall(r'^\s*' + re.escape(e) + r' = (.*)$', text, re.M)
        if defs: return source(text, defs[-1])
    return e

def main(scripts, props_path):
    props = collections.defaultdict(set)  # (script, property) -> values in plugins
    for line in open(props_path):
        cols = line.rstrip("\n").split("\t")
        if len(cols) == 3: props[cols[0], cols[1]].add(float(cols[2]))

    src, children, patched = {}, collections.defaultdict(list), set()
    for f in os.listdir(scripts):
        if f.endswith(".patch.lua"): patched.add(f[:-len(".patch.lua")])
        elif f.endswith(".lua"):
            t = open(os.path.join(scripts, f), errors="replace").read()
            src[f[:-4]] = t
            m = CLASS.search(t)
            if m: children[m.group(2).lower()].append(f[:-4])

    def family(n):
        out, todo = [], [n]
        while todo:
            x = todo.pop()
            out.append(x)
            todo += children[x]
        return out

    print("# generated: tools/tickrates.py over the installed SE scripts and --vmad-props of every plugin")
    print("# script\thz\twhy\twaits")
    for n, t in sorted(src.items()):
        if n in patched: continue
        found = [(m.group(1), m.start()) for m in WAIT.finditer(t) if m.group(1) != "rt.None"]
        if not found: continue
        defaults = dict(DEFAULT.findall(t))
        prop_of = {v: k for k, v in AUTOPROP.findall(t)}
        waits, from_props, unknown = [], set(), set()
        for e, at in found:
            e = source(t[:at], e)
            m = LIT.match(e)
            if m:
                waits.append(float(m.group(1)))
                continue
            m = VAR.match(e)
            if m and m.group(1) in defaults:
                var = m.group(1)
                p = prop_of.get(var, var)
                waits.append(0.0 if defaults[var] == "nil" else float(defaults[var]))
                for c in family(n): waits += props.get((c, p), ())
                from_props.add(p)
                continue
            unknown.add("random" if "rand" in e.lower() else e)
        if unknown == {"random"}: why = "random wait"
        elif unknown: why = "computed wait: " + ", ".join(sorted(unknown))
        elif from_props: why = "waits and plugin values of " + ", ".join(sorted(from_props))
        else: why = "literal waits"
        print(f"{n}\t{hz(waits)}\t{why}\t{' '.join('%g' % w for w in sorted(set(waits)))}")

main(sys.argv[1], sys.argv[2])
