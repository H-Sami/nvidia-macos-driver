#!/usr/bin/env python3
"""compare.py BASE RUN [FILTER] - prints a Markdown table of every metric in the two runs' summary.json, BASE (usually
the stock baseline) against RUN, with the change. FILTER keeps metrics whose name contains it (e.g. desktop.drag)."""
import json, os, sys

if len(sys.argv) not in (3, 4): sys.exit(__doc__)
a, b = (json.load(open(os.path.join(p, 'summary.json'))) for p in sys.argv[1:3])
f = sys.argv[3] if len(sys.argv) == 4 else ''
print(f'| metric | {os.path.basename(sys.argv[1].rstrip("/"))} | {os.path.basename(sys.argv[2].rstrip("/"))} | change |')
print('|---|---|---|---|')
for k in sorted(set(a) | set(b)):
    if f not in k: continue
    x, y = a.get(k), b.get(k)
    ch = ''
    if isinstance(x, (int, float)) and isinstance(y, (int, float)):
        ch = f'{y - x:+.4g}' + (f' ({(y - x) / x * 100:+.0f}%)' if x else '')
    print(f'| {k} | {"-" if x is None else x} | {"-" if y is None else y} | {ch} |')
