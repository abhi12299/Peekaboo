import json, sys
rows = [json.loads(l) for l in open(sys.argv[1]) if l.strip()]
if not rows: print("no samples"); sys.exit()
print(f"samples={len(rows)} span={rows[-1]['t']-rows[0]['t']:.0f}s")
prev = None; moves = 0
for r in rows:
    if prev and (r['cx'], r['cy']) != (prev['cx'], prev['cy']): moves += 1
    if prev is None or r['front'] != prev['front']: print(f"  +{r['t']-rows[0]['t']:6.1f}s frontmost -> {r['front']}")
    prev = r
print("cursor position changes:", moves)
owners = {}
for r in rows:
    for w in r['wins']:
        k = (w['owner'], w['layer'], round(w['w']), round(w['h']))
        owners.setdefault(k, [0, r['t'] - rows[0]['t'], None]); owners[k][0] += 1; owners[k][2] = r['t'] - rows[0]['t']
for (o, layer, w, h), (n, first, last) in sorted(owners.items(), key=lambda x: -x[1][0])[:12]:
    print(f"  overlay owner={o!r} layer={layer} size={w}x{h} seen={n} samples from +{first:.0f}s to +{last:.0f}s")
