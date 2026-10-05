"""Compare baseline and fused MTP in one pod, without downloading again."""
import json
import os
from pathlib import Path
import signal
import subprocess
import time
import urllib.request

ROOT = Path(os.environ.get('MODEL_DIR', '/models'))
URL = 'http://127.0.0.1:8080'
PROMPTS = [
    ('code', 'Implement a Python LRU cache with get and put, using OrderedDict. Include explanations and a usage example.'),
    ('prose', 'Write twenty practical tips for debugging Python programs, each with a short explanation.'),
    ('context', ('def normalize_record(record):\n    return {str(k).strip(): v for k, v in record.items()}\n' * 80) + '\nReview this code and propose a robust implementation with validation and tests.'),
]

def call(path, body=None):
    headers = {'Authorization': 'Bearer ' + os.environ['LLAMA_API_KEY'], 'Content-Type': 'application/json'}
    data = json.dumps(body).encode() if body is not None else None
    with urllib.request.urlopen(urllib.request.Request(URL + path, data=data, headers=headers), timeout=180) as response:
        return json.load(response)

results = []
for mode in (0, 1, 2):
    env = {**os.environ, 'SPEC_DRAFT_N_MAX': str(mode)}
    process = subprocess.Popen(['sh', os.environ['SERVER_PATH']], env=env, start_new_session=True)
    try:
        deadline = time.monotonic() + 180
        while time.monotonic() < deadline:
            if process.poll() is not None:
                raise RuntimeError('Server exited while loading benchmark mode ' + str(mode))
            try:
                call('/health')
                break
            except Exception:
                time.sleep(2)
        else:
            raise RuntimeError('Benchmark server did not start')
        # The shell guard prints offload evidence shortly after health turns green.
        time.sleep(3)
        call('/chat/completions', {'messages': [{'role': 'user', 'content': 'Say hello.'}], 'max_tokens': 16, 'temperature': 0, 'cache_prompt': False})
        rows = []
        for repeat in range(2):
            for label, prompt in PROMPTS:
                started = time.monotonic()
                response = call('/chat/completions', {'messages': [{'role': 'user', 'content': prompt}],
                    'max_tokens': 256, 'temperature': 0, 'seed': 42, 'cache_prompt': False})
                row = {'prompt': label, 'repeat': repeat, 'wall_seconds': round(time.monotonic()-started, 3),
                       'timings': response['timings'], 'usage': response.get('usage')}
                rows.append(row)
        totals = {k: sum(row['timings'][k] for row in rows) for k in ('predicted_n', 'predicted_ms', 'prompt_n', 'prompt_ms')}
        result = {'spec_draft_n_max': mode, 'tokens_per_second': totals['predicted_n'] * 1000 / totals['predicted_ms'],
                  'total_wall_seconds': sum(row['wall_seconds'] for row in rows), 'runs': rows}
        results.append(result)
        print('BENCHMARK_RESULT ' + json.dumps(result), flush=True)
        (ROOT / 'benchmark.json').write_text(json.dumps(results, indent=2))
    finally:
        if process.poll() is None:
            os.killpg(process.pid, signal.SIGTERM)
        try:
            process.wait(timeout=20)
        except subprocess.TimeoutExpired:
            os.killpg(process.pid, signal.SIGKILL)
            process.wait()
        time.sleep(2)
# Select overall request time, including prompt processing, with a 3% minimum win.
baseline = results[0]
winner = min(results, key=lambda row: row['total_wall_seconds'])
if winner['total_wall_seconds'] > baseline['total_wall_seconds'] * 0.97:
    winner = baseline
(ROOT / 'speculation.env').write_text('SPEC_DRAFT_N_MAX=' + str(winner['spec_draft_n_max']) + '\n')
print('BENCHMARK_SELECTED ' + json.dumps({'spec_draft_n_max': winner['spec_draft_n_max'], 'results': results}), flush=True)
