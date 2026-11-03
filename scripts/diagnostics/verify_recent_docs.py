"""Compare Wine Recent persistence with and without the host menu builder.

Uses an isolated disposable prefix; never opens SOLIDWORKS or user documents.
"""
import argparse
import json
import os
from pathlib import Path
import runpy
import subprocess
import tempfile

PROJECT = Path(__file__).resolve().parents[2]

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--app', type=Path, required=True)
    parser.add_argument('--evidence', type=Path, required=True)
    args = parser.parse_args()
    evidence = args.evidence.resolve()
    evidence.mkdir(parents=True, exist_ok=True)
    contents = args.app.resolve() / 'Contents'
    runtime = runpy.run_path(str(PROJECT / 'scripts/swcli/wine_runtime.py'))
    results = []
    for arch, compiler in [('x64', 'x86_64-w64-mingw32-gcc'), ('x86', 'i686-w64-mingw32-gcc')]:
        subprocess.run([compiler, '-O2', '-Wall', '-Werror', '-municode',
                        str(PROJECT / 'native/wine_recent_docs_probe.c'),
                        '-o', str(evidence / ('recent-' + arch + '.exe')),
                        '-lole32', '-luuid', '-lshell32'], check=True)
    with tempfile.TemporaryDirectory(prefix='MacSW-recent-probe-') as directory:
        env = runtime['environment'](contents, Path(directory) / 'bottle')
        env['WINEDLLOVERRIDES'] += ';mscoree,mshtml='
        def run(name, arguments, *, timeout=45):
            log = evidence / (name + '.log')
            with log.open('xb') as output:
                result = subprocess.run([env['WINELOADER'], *map(str, arguments)],
                                        env=env, stdin=subprocess.DEVNULL,
                                        stdout=output, stderr=subprocess.STDOUT, timeout=timeout)
            if result.returncode:
                raise RuntimeError(f'{name} exited {result.returncode}; see {log}')
            return log.read_text(errors='replace').splitlines()
        try:
            run('wineboot', ['wineboot.exe', '-u'], timeout=120)
            env['WINEDEBUG'] = '-all,+timestamp,+pid,+tid,+process'
            for enabled in (True, False):
                env['WINEDLLOVERRIDES'] = 'mscoree,mshtml=' + ('' if enabled else ';winemenubuilder.exe=d')
                for arch in ('x64', 'x86'):
                    name = arch + ('-baseline' if enabled else '-disabled')
                    lines = run(name, [evidence / ('recent-' + arch + '.exe'), 'recent', name])
                    outcome = [line for line in lines if line.startswith('recent_link_target=')]
                    created = sum('NtCreateUserProcess' in line and 'winemenubuilder.exe' in line
                                  and ' pid ' in line for line in lines)
                    if not outcome or not outcome[0].startswith('recent_link_target=PASS '):
                        raise AssertionError(f'Recent link/MRU persistence failed: {name}')
                    if (enabled and not created) or (not enabled and created):
                        raise AssertionError(f'Unexpected menu-builder process count: {name}: {created}')
                    row = dict(case=name, menu_builder_created=created, persistence=outcome[0])
                    results.append(row)
                    print(json.dumps(row), flush=True)
        finally:
            # This server belongs solely to the disposable probe prefix.
            subprocess.run([env['WINESERVER'], '-k'], env=env, timeout=15, check=False)
            subprocess.run([env['WINESERVER'], '-w'], env=env, timeout=15, check=True)
    (evidence / 'results.json').write_text(json.dumps(results, indent=2) + '\n')

if __name__ == '__main__':
    main()
