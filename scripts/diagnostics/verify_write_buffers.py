"""Bounded x86/x64 progress checks for Wine's macOS process-wide barrier.

Uses a disposable prefix only. --runtime accepts an independently prepared
runtime for development; CI checks the runtime in the packaged App.
"""
import argparse
import json
import os
from pathlib import Path
import subprocess
import tempfile

PROJECT = Path(__file__).resolve().parents[2]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    choice = parser.add_mutually_exclusive_group(required=True)
    choice.add_argument('--app', type=Path)
    choice.add_argument('--runtime', type=Path)
    parser.add_argument('--evidence', type=Path, required=True)
    args = parser.parse_args()
    wine = (args.runtime or args.app / 'Contents/Frameworks/wine').resolve()
    loader = wine / 'lib/wine/x86_64-unix/MacSW'
    server = wine / 'bin/wineserver'
    if not loader.is_file() or not server.is_file():
        raise RuntimeError('Wine loader or wineserver is missing')
    evidence = args.evidence.resolve()
    # Separate runs must not overwrite a previous failure's evidence.
    evidence.mkdir(parents=True, exist_ok=False)
    results = []
    for arch, compiler in [('x64', 'x86_64-w64-mingw32-gcc'), ('x86', 'i686-w64-mingw32-gcc')]:
        subprocess.run([compiler, '-O2', '-Wall', '-Wextra', '-Werror',
                        str(PROJECT / 'native/wine_write_buffers_probe.c'),
                        '-o', str(evidence / (arch + '.exe'))], check=True)
    with tempfile.TemporaryDirectory(prefix='MacSW-write-buffers-') as directory:
        env = dict(os.environ, WINEPREFIX=str(Path(directory) / 'bottle'),
                   WINELOADER=str(loader), WINESERVER=str(server), WINEDEBUG='-all',
                   WINEDLLOVERRIDES='winemenubuilder.exe=d;mscoree,mshtml=')
        def run(name, arguments, timeout):
            log = evidence / (name + '.log')
            with log.open('xb') as output:
                result = subprocess.run([str(loader), *map(str, arguments)], env=env,
                                        stdin=subprocess.DEVNULL, stdout=output,
                                        stderr=subprocess.STDOUT, timeout=timeout)
            row = dict(case=name, exit_code=result.returncode)
            results.append(row)
            print(json.dumps(row), flush=True)
            if result.returncode:
                raise RuntimeError(f'{name} exited {result.returncode}; see {log}')
            return log.read_text(errors='replace')
        try:
            run('wineboot', [r'C:\windows\system32\wineboot.exe', '-u'], 240)
            for arch in ('x64', 'x86'):
                for threads in (1, 8):
                    text = run(f'{arch}-{threads}', [evidence / (arch + '.exe'), threads], 60)
                    if 'WINE_WRITE_BUFFERS_PASS' not in text:
                        raise AssertionError(f'{arch}-{threads} did not report completion')
        finally:
            (evidence / 'results.json').write_text(json.dumps(results, indent=2) + '\n')
            # Only the fresh prefix above is stopped, including timed-out probes.
            subprocess.run([str(server), '-k'], env=env, timeout=15, check=False)
            subprocess.run([str(server), '-w'], env=env, timeout=15, check=True)


if __name__ == '__main__':
    main()
