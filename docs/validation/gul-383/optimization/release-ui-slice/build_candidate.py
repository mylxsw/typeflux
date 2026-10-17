"""Prepare isolated dependency caches, then build only current release products."""
import argparse, hashlib, json, os, signal, subprocess, time
from pathlib import Path

parser = argparse.ArgumentParser()
parser.add_argument('--cache', type=Path, required=True)
parser.add_argument('--timeout', type=int, default=600)
args = parser.parse_args()
root = Path.cwd()
out = root / 'docs/validation/gul-383/optimization/release-ui-slice'
started = time.monotonic()
cache = args.cache.resolve()
(root / '.build').mkdir(exist_ok=True)
records = []
for name in ['checkouts', 'artifacts', 'repositories', 'workspace-state.json']:
    source = cache / name
    if source.exists() and not (root / '.build' / name).exists():
        before = time.monotonic()
        subprocess.run(['cp', '-cR', str(source), str(root / '.build' / name)], check=True)
        records.append({'phase': 'clone-' + name, 'wall_seconds': time.monotonic() - before})
command = ['swift', 'build', '-c', 'release', '--jobs', '4', '-Xswiftc', '-enable-testing']
env = {k: v for k, v in os.environ.items() if not any(s in k.upper() for s in ['TOKEN','SECRET','PASSWORD','API_KEY','MULTICA_','CODEX_'])}
with (out / 'release-build.log').open('w') as log:
    before = time.monotonic()
    child = subprocess.Popen(command, cwd=root, env=env, stdout=log, stderr=subprocess.STDOUT, start_new_session=True)
    try:
        code = child.wait(timeout=args.timeout)
    except subprocess.TimeoutExpired:
        os.killpg(child.pid, signal.SIGTERM)
        try:
            child.wait(timeout=10)
        except subprocess.TimeoutExpired:
            os.killpg(child.pid, signal.SIGKILL)
            child.wait()
        code = 124
    records.append({'phase': 'current-source-release', 'command': command, 'wall_seconds': time.monotonic()-before, 'exit_code': code})
report = {'source_commit': subprocess.check_output(['git','rev-parse','HEAD'],text=True).strip(), 'records': records, 'wall_seconds': time.monotonic()-started, 'exit_code': code}
(out/'release-build.json').write_text(json.dumps(report,indent=2)+'\n')
print(json.dumps(report))
raise SystemExit(code)
