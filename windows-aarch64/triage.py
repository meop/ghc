#!/usr/bin/env python3
"""Turn a GHC testsuite junit.xml into a TSV: test, way, result, first-error-line.

Usage (from anywhere):
    uv run --no-project python -I triage.py JUNIT.xml [-o OUT.tsv]
    uv run --no-project python -I triage.py --join A=a.tsv B=b.tsv X=x.tsv [-o joined.tsv]
    uv run --no-project python -I triage.py JUNIT.xml --show 'REGEX'   # full bodies of matching failures

result is one of: pass, fail (unexpected failure), framework (framework failure),
fragile (skipped "fragile failure"), skip (any other <skipped>).
Expected failures are reported by the driver as passes, so they appear as pass.

first-error-line is "<message> | <first informative line of the body>", with tabs and
newlines flattened; empty for passes.

--join reads the TSVs produced above and writes one row per (test, way) with a
result column per label, ('-' where the entry is absent from that run).
"""
import argparse
import re
import sys
import xml.etree.ElementTree as ET

# Lines that carry no information about what went wrong.
BORING = re.compile(
    r"^\s*(=+|-+|stdout:|stderr:|Actual (stdout|stderr) output differs.*|"
    r"Actual (stdout|stderr) \(.*|Expected .*|Wrong exit code.*|\*\*\* unexpected failure.*|"
    r"\+\+\+ .*|--- .*|@@ .*|Output was|Compile failed.*|Run (stdout|stderr).*|"
    r"Compilation failed.*|diff:)$"
)
NAME = re.compile(r"^(.*)\(([^()]*)\)$")


# Progress chatter that is never the error itself.
CHATTER = re.compile(r"^\s*(\[\s*\d+ of \d+\]|Loaded package|Linking |Preprocessing |Building |Configuring |In file included from)")
ERRISH = re.compile(
    r"(error|cannot|can't|failed|fail:|not found|No such|invalid|undefined|Could not|panic|"
    r"exception|unable|unknown|segmentation|access violation|mismatch|differ)", re.I)


def first_line(text):
    cands = [l.rstrip() for l in (text or "").splitlines() if l.strip()]
    good = [l for l in cands if not BORING.match(l) and not CHATTER.match(l)]
    for l in good:
        if ERRISH.search(l):
            return l.strip()
    if good:
        return good[0].strip()
    return cands[0].strip() if cands else ""


def parse(path):
    rows = []
    for ev, el in ET.iterparse(path, events=("end",)):
        if el.tag != "testcase":
            continue
        name = el.get("name", "")
        m = NAME.match(name)
        test, way = (m.group(1), m.group(2)) if m else (name, el.get("classname", ""))
        res, info = "pass", ""
        for ch in el:
            if ch.tag == "failure":
                res = "fail"
            elif ch.tag == "error":
                res = "framework"
            elif ch.tag == "skipped":
                res = "fragile" if "fragile" in (ch.get("type") or "") else "skip"
            else:
                continue
            msg = ch.get("message") or ""
            body = first_line(ch.text)
            info = msg if (not body or body == msg) else f"{msg} | {body}"
            break
        info = re.sub(r"[\t\r\n]+", " ", info)[:400]
        rows.append((test, way, res, info))
        el.clear()
    return rows


def show(path, pat):
    """Print the full report body of every non-passing testcase whose name matches pat."""
    rx = re.compile(pat)
    for ev, el in ET.iterparse(path, events=("end",)):
        if el.tag == "testcase" and rx.search(el.get("name", "")):
            for ch in el:
                print("=== %s [%s] %s" % (el.get("name"), ch.tag, ch.get("message")))
                print(ch.text or "")
        if el.tag == "testcase":
            el.clear()


def write_tsv(rows, out):
    out.write("test\tway\tresult\tfirst_error_line\n")
    for r in rows:
        out.write("\t".join(r) + "\n")


def read_tsv(path):
    d = {}
    with open(path, encoding="utf-8") as f:
        next(f)
        for line in f:
            p = line.rstrip("\n").split("\t")
            p += [""] * (4 - len(p))
            d[(p[0], p[1])] = (p[2], p[3])
    return d


def join(specs, out):
    labels, tabs = [], []
    for s in specs:
        lab, _, path = s.partition("=")
        labels.append(lab)
        tabs.append(read_tsv(path))
    keys = sorted(set().union(*[t.keys() for t in tabs]))
    out.write("test\tway\t" + "\t".join(labels) + "\t" + "\t".join(l + "_err" for l in labels) + "\n")
    for k in keys:
        res = [t.get(k, ("-", ""))[0] for t in tabs]
        err = [t.get(k, ("-", ""))[1] for t in tabs]
        out.write("\t".join(list(k) + res + err) + "\n")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("inputs", nargs="+")
    ap.add_argument("-o", "--output")
    ap.add_argument("--join", action="store_true", help="inputs are LABEL=file.tsv")
    ap.add_argument("--show", metavar="REGEX", help="print full bodies of failing cases matching REGEX")
    a = ap.parse_args()
    if a.show:
        show(a.inputs[0], a.show)
        return
    out = open(a.output, "w", encoding="utf-8", newline="\n") if a.output else sys.stdout
    if a.join:
        join(a.inputs, out)
    else:
        if len(a.inputs) != 1:
            ap.error("one junit file expected")
        write_tsv(parse(a.inputs[0]), out)
    if a.output:
        out.close()


if __name__ == "__main__":
    main()
