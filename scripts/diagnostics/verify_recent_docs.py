"""Verify that MacSW does not even request a menu-builder process.

Uses disposable prefixes only; never opens SOLIDWORKS or user documents.
An optional old App demonstrates that a disabled executable still receives
NtCreateUserProcess requests, despite no successful child being reported.
"""
import argparse
import json
import os
from pathlib import Path
import runpy
import shutil
import subprocess
import tempfile

PROJECT = Path(__file__).resolve().parents[2]

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--app', type=Path, required=True)
    parser.add_argument('--baseline-app', type=Path)
    parser.add_argument('--shell32-dir', type=Path,
                        help='Optional freshly built x86_64-windows/i386-windows module directory')
    parser.add_argument('--evidence', type=Path, required=True)
    args = parser.parse_args()
    evidence = args.evidence.resolve()
    evidence.mkdir(parents=True, exist_ok=True)
    runtime = runpy.run_path(str(PROJECT / 'scripts/swcli/wine_runtime.py'))
    results = []
    for arch, compiler in [('x64', 'x86_64-w64-mingw32-gcc'), ('x86', 'i686-w64-mingw32-gcc')]:
        subprocess.run([compiler, '-O2', '-Wall', '-Werror', '-municode',
                        str(PROJECT / 'native/wine_recent_docs_probe.c'),
                        '-o', str(evidence / ('recent-' + arch + '.exe')),
                        '-lole32', '-luuid', '-lshell32'], check=True)
    candidate_runtime = None
    if args.shell32_dir:
        # Builtin PE modules are re-resolved in the loader's runtime directory;
        # replacing a prefix copy does not override the installed builtin DLL.
        candidate_runtime = evidence / 'runtime'
        subprocess.run(['/bin/cp', '-cR', str((args.app.resolve() / 'Contents/Frameworks/wine').resolve()),
                        str(candidate_runtime)], check=True)
        for arch in ('x86_64-windows', 'i386-windows'):
            destination = candidate_runtime / 'lib/wine' / arch / 'shell32.dll'
            staged = destination.with_suffix('.candidate')
            shutil.copyfile(args.shell32_dir.resolve() / arch / 'shell32.dll', staged)
            os.replace(staged, destination)
    plans = []
    if args.baseline_app:
        plans.append(('legacy-disabled', args.baseline_app, None, True))
    plans.append(('early-blocked', args.app, candidate_runtime, False))
    for profile, app, runtime_override, expect_requests in plans:
        with tempfile.TemporaryDirectory(prefix='MacSW-recent-probe-') as directory:
            prefix = Path(directory) / 'bottle'
            contents = app.resolve() / 'Contents'
            env = runtime['environment'](contents, prefix)
            if runtime_override:
                env['WINELOADER'] = str(runtime_override / 'lib/wine/x86_64-unix/MacSW')
                env['WINESERVER'] = str(runtime_override / 'bin/wineserver')
            env['WINEDLLOVERRIDES'] = 'winemenubuilder.exe=d;mscoree,mshtml='
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
                run(profile + '-wineboot', ['wineboot.exe', '-u'], timeout=120)
                env['WINEDEBUG'] = '-all,+timestamp,+pid,+tid,+process'
                for arch in ('x64', 'x86'):
                    name = arch + '-' + profile
                    lines = run(name, [evidence / ('recent-' + arch + '.exe'), 'recent', name])
                    outcome = [line for line in lines if line.startswith('recent_link_target=')]
                    requests = sum('NtCreateUserProcess' in line and 'winemenubuilder.exe' in line
                                   and ' image ' in line for line in lines)
                    created = sum('NtCreateUserProcess' in line and 'winemenubuilder.exe' in line
                                  and ' pid ' in line for line in lines)
                    if not outcome or not outcome[0].startswith('recent_link_target=PASS '):
                        raise AssertionError(f'Recent link/MRU persistence failed: {name}')
                    if created or bool(requests) != expect_requests:
                        raise AssertionError(f'Unexpected menu-builder requests/children: {name}: {requests}/{created}')
                    row = dict(case=name, menu_builder_requests=requests,
                               menu_builder_created=created, persistence=outcome[0])
                    results.append(row)
                    print(json.dumps(row), flush=True)
            finally:
                subprocess.run([env['WINESERVER'], '-k'], env=env, timeout=15, check=False)
                subprocess.run([env['WINESERVER'], '-w'], env=env, timeout=15, check=True)
    (evidence / 'results.json').write_text(json.dumps(results, indent=2) + '\n')

if __name__ == '__main__':
    main()
