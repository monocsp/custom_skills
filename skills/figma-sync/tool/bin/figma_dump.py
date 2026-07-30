#!/usr/bin/env python3
"""Figma node dumper — fetch a node subtree and dump structure + all TEXT verbatim.

Usage:
  python3 figma_dump.py <node-id> [--out <prefix>] [--depth N] [--tree] [--file-key KEY]

Examples:
  python3 figma_dump.py 1788:46055 --out mypolicy
  python3 figma_dump.py 2794:145799 --depth 3 --tree

File key resolution (no hardcoded key — public identifier still, but kept out of source):
  1) --file-key KEY  argument, else
  2) FIGMA_FILE_KEY   in the figma-sync skill .env (same file as FIGMA_TOKEN), else error.

Outputs (in the scratchpad dir):
  <prefix>.raw.json   full API response
  <prefix>.texts.txt  every TEXT node verbatim, sorted top-left, with id/pos
  <prefix>.tree.txt   indented structure (when --tree)
Prints the texts to stdout too.
"""
import json
import os
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
# .env lives at the figma-sync skill root (this script sits in tool/bin/ -> ../../.env).
ENV = os.path.normpath(os.path.join(HERE, "..", "..", ".env"))


def _env(key):
    """Read a single value from the skill .env by key name; None if file/key absent."""
    try:
        with open(ENV, encoding="utf-8") as f:
            for line in f:
                line = line.strip()
                if line.startswith(key + "="):
                    return line.split("=", 1)[1].strip()
    except FileNotFoundError:
        return None
    return None


def token():
    tok = _env("FIGMA_TOKEN")
    if not tok:
        sys.exit(f"no FIGMA_TOKEN in {ENV}")
    return tok


def fetch(node_id, file_key, depth=None):
    url = f"https://api.figma.com/v1/files/{file_key}/nodes?ids={node_id}"
    if depth:
        url += f"&depth={depth}"
    r = subprocess.run(
        ["curl", "-s", "-H", f"X-Figma-Token: {token()}", url],
        capture_output=True, text=True, check=True,
    )
    return json.loads(r.stdout)


def collect(node, out, path=()):
    bb = node.get("absoluteBoundingBox") or {}
    if node.get("type") == "TEXT" and (node.get("characters") or "").strip():
        st = node.get("style") or {}
        out.append({
            "id": node.get("id"),
            "x": bb.get("x"), "y": bb.get("y"),
            "w": bb.get("width"), "h": bb.get("height"),
            "size": st.get("fontSize"), "weight": st.get("fontWeight"),
            "font": st.get("fontFamily"),
            "path": " > ".join(path[-4:]),
            "chars": node.get("characters"),
        })
    for c in node.get("children") or []:
        collect(c, out, path + (str(node.get("name")),))


def tree_lines(node, lines, indent=0, maxdepth=99):
    if indent > maxdepth:
        return
    bb = node.get("absoluteBoundingBox") or {}
    nm = str(node.get("name"))[:50]
    dims = f"{bb.get('width', 0):.0f}x{bb.get('height', 0):.0f}" if bb else "-"
    txt = ""
    if node.get("type") == "TEXT":
        txt = " :: " + (node.get("characters") or "").replace("\n", "⏎")[:60]
    lines.append(f"{'  ' * indent}{node.get('type', '?'):13s} {node.get('id', ''):16s} {dims:>12s}  {nm!r}{txt}")
    for c in node.get("children") or []:
        tree_lines(c, lines, indent + 1, maxdepth)


def main():
    args = sys.argv[1:]
    if not args:
        sys.exit(__doc__)
    node_id = args[0]
    prefix = node_id.replace(":", "_")
    depth = None
    file_key = _env("FIGMA_FILE_KEY")
    want_tree = "--tree" in args
    if "--out" in args:
        prefix = args[args.index("--out") + 1]
    if "--depth" in args:
        depth = args[args.index("--depth") + 1]
    if "--file-key" in args:
        file_key = args[args.index("--file-key") + 1]
    if not file_key:
        sys.exit("no Figma file key: pass --file-key KEY or set FIGMA_FILE_KEY in the skill .env")

    data = fetch(node_id, file_key, depth)
    if data.get("err"):
        sys.exit(f"Figma API error: {data['err']}")
    key = node_id.replace("-", ":")
    entry = (data.get("nodes") or {}).get(key)
    if not entry:
        sys.exit(f"node {key} not in response; got {list((data.get('nodes') or {}).keys())}")
    doc = entry["document"]

    raw_p = os.path.join(HERE, f"{prefix}.raw.json")
    json.dump(data, open(raw_p, "w"), ensure_ascii=False)

    texts = []
    collect(doc, texts)
    texts.sort(key=lambda t: ((t["y"] or 0) // 50, t["x"] or 0))

    out = [f"# node {key} :: {doc.get('name')!r} ({doc.get('type')})",
           f"# TEXT nodes: {len(texts)}  total chars: {sum(len(t['chars']) for t in texts)}", ""]
    for t in texts:
        out.append(f"--- id={t['id']} pos=({t['x']:.0f},{t['y']:.0f}) size={t['w']:.0f}x{t['h']:.0f} "
                   f"font={t['font']}/{t['size']}/{t['weight']} path={t['path']}")
        out.append(t["chars"])
        out.append("")
    body = "\n".join(out)
    open(os.path.join(HERE, f"{prefix}.texts.txt"), "w", encoding="utf-8").write(body)

    if want_tree:
        lines = []
        tree_lines(doc, lines)
        open(os.path.join(HERE, f"{prefix}.tree.txt"), "w", encoding="utf-8").write("\n".join(lines))
        print(f"[tree] {prefix}.tree.txt ({len(lines)} nodes)")

    print(body)
    print(f"\n[saved] {prefix}.raw.json / {prefix}.texts.txt")


if __name__ == "__main__":
    main()
