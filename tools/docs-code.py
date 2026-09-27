"""Every line of Pascal in docs/ is in examples/docs.lpr, which ./check
compiles. A page cannot then show code that does not build: the line would
be missing there, or the file would not compile.

Two kinds of line are held differently:

* A unit named in a `uses` on a page must be in the uses clause of
  docs.lpr. A wrong unit name is the likeliest mistake in an example, and
  it is on a line no statement comparison would see.
* Comments are prose, across line breaks too, and blank lines and lines
  that only open or close a block carry no name that could be wrong.

Everything else must appear in docs.lpr as it stands, trimmed."""
import re, sys, pathlib

root = pathlib.Path(__file__).resolve().parent.parent
lpr = (root / 'examples/docs.lpr').read_text()


def strip_comments(text):
    out, depth = [], 0
    for line in text.splitlines():
        kept, i = '', 0
        while i < len(line):
            c = line[i]
            if depth == 0 and line.startswith('//', i):
                break
            if c == '{':
                depth += 1
            elif c == '}' and depth:
                depth -= 1
            elif depth == 0:
                kept += c
            i += 1
        out.append(kept.rstrip())
    return out


lpr_lines = strip_comments(lpr)
compiled = {l.strip() for l in lpr_lines}
m = re.search(r'\buses\b(.*?);', '\n'.join(lpr_lines), re.S)
lpr_units = {u.strip() for u in m.group(1).split(',')}

skip = re.compile(r"^(begin|end;?|end\.|var|const|try|finally|except|else)$")
missing = []
for md in sorted((root / 'docs').glob('*.md')):
    blocks, cur, inside = [], [], False
    for n, line in enumerate(md.read_text().splitlines(), 1):
        if line.startswith('```'):
            if inside:
                blocks.append(cur)
                cur, inside = [], False
            elif line.strip() == '```pascal':
                inside = True
            continue
        if inside:
            cur.append((n, line))
    for block in blocks:
        text = strip_comments('\n'.join(l for _, l in block))
        in_uses = False
        for (n, _), code in zip(block, text):
            s = code.strip()
            if not s:
                continue
            if in_uses or s.startswith('uses'):
                names = s[4:] if s.startswith('uses') else s
                in_uses = not names.rstrip().endswith(';')
                for u in names.replace(';', '').split(','):
                    u = u.strip()
                    if u and u not in lpr_units:
                        missing.append(f"{md.name}:{n}: the unit {u} is not in docs.lpr's uses")
                continue
            if skip.match(s):
                continue
            if s not in compiled:
                missing.append(f"{md.name}:{n}: {s}")

for line in missing:
    print(line)
print(f"{len(missing)} line(s) of docs/ code not in examples/docs.lpr", file=sys.stderr)
sys.exit(1 if missing else 0)
