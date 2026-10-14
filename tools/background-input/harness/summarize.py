# Usage: python3 summarize.py runs/<dir> [...]  — one-line-per-run summary for Codex or Claude transcripts.
import json, sys, collections, os, subprocess
for d in sys.argv[1:]:
    calls = collections.Counter(); errors = 0; batches = 0
    for line in open(os.path.join(d, 'transcript.jsonl')):
        try: e = json.loads(line)
        except ValueError: continue
        item = e.get('item', {})
        if e.get('type') == 'item.completed' and item.get('type') == 'mcp_tool_call':  # Codex
            calls[item.get('tool')] += 1; errors += bool(item.get('status') == 'failed' or item.get('error'))
        if e.get('type') == 'assistant':  # Claude
            for c in e['message'].get('content', []):
                if c.get('type') == 'tool_use':
                    name = c['name'].split('__')[-1]; calls[name] += 1; batches += name == 'batch'
        if e.get('type') == 'user':
            for c in e['message'].get('content', []):
                errors += isinstance(c, dict) and c.get('type') == 'tool_result' and bool(c.get('is_error'))
    timing = open(os.path.join(d, 'timing.txt')).read().strip()
    result = open(os.path.join(d, 'result.txt')).read().strip()
    crashes = os.path.join(d, 'crashes.txt')
    crashes = [os.path.basename(l.strip()) for l in open(crashes)] if os.path.exists(crashes) else []
    sampler = subprocess.run([sys.executable, 'analyze_sampler.py', os.path.join(d, 'sampler.jsonl')], capture_output=True, text=True).stdout
    fronts = [l.split('-> ')[1] for l in sampler.splitlines() if 'frontmost ->' in l]
    moves = [l.split(': ')[1] for l in sampler.splitlines() if l.startswith('cursor position changes')]
    print(f"{os.path.basename(d)}: {timing} | {result} | calls={sum(calls.values())} batch={batches} errors={errors} | front={'>'.join(fronts)} cursor_moves={moves[0] if moves else '?'} | crashes={crashes}")
