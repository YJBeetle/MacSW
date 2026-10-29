"""Exercise the real Wine dialog ABI with captured native-panel responses.

No UI automation or SOLIDWORKS is used. Each run owns a fresh Wine prefix.
The captured helper validates request framing and returns selected host paths;
this checks Wine's UTF-16, cancellation, multiselect and buffer contracts.
"""
import argparse
import json
import os
from pathlib import Path
import struct
import subprocess
import sys
import tempfile

PROJECT = Path(__file__).resolve().parents[2]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--app', type=Path, required=True)
    parser.add_argument('--evidence', type=Path, required=True)
    parser.add_argument('--case', action='append', dest='cases', help='Run only this named ABI case (repeatable).')
    args = parser.parse_args()
    args.evidence.mkdir(parents=True, exist_ok=True)
    subprocess.run(['bash', str(PROJECT / 'scripts/build_wine_file_panel_probe.sh')], check=True)
    wine = args.app.resolve() / 'Contents/Frameworks/wine'
    with tempfile.TemporaryDirectory(prefix='macsw-panel-abi-', dir='/private/tmp') as directory:
        root = Path(directory)
        fixtures = root / "中文 folder, ' $(literal)"
        fixtures.mkdir()
        for name in ['模型一.SLDPRT', '模型二.SLDPRT']:
            (fixtures / name).write_text('native dialog ABI fixture')
        helper = root / 'captured-panel'
        helper.write_text('#!' + sys.executable + '\n' + r'''
import json, os, pathlib, struct, sys, time
request, response = map(pathlib.Path, sys.argv[1:])
data = request.read_bytes()
magic, version, mode, flags, index, count = struct.unpack_from('<6I', data)
assert (magic, version) == (0x4d535046, 1) and mode in (1, 2) and count == 3
offset = 24
strings = []
for i in range(4 + count * 2):
    end = offset
    while data[end:end+2] != b'\0\0': end += 2
    strings.append(data[offset:end].decode('utf-16le'))
    offset = end + 2
sequence, controls = struct.unpack_from('<2I', data, offset)
assert sequence == 0
assert strings[0] == 'MacSW 原生面板验证'
assert strings[5] == '*.SLDPRT' and strings[7] == '*.step;*.stp'
case = os.environ['MACSW_PANEL_CASE']
if case == 'com-save-wildcard': assert strings[2] == '原生面板验证.SLDPRT', strings[2]
if case == 'com-save-controls':
    def snapshot(packet):
        header = struct.unpack_from('<6I', packet)
        cursor = 24
        def read_text():
            nonlocal cursor
            end = cursor
            while end + 2 <= len(packet) and packet[end:end+2] != b'\0\0': end += 2
            if end + 2 > len(packet): raise IndexError('request update is incomplete')
            value = packet[cursor:end].decode('utf-16le')
            cursor = end + 2
            return value
        for unused in range(4 + header[5] * 2): read_text()
        seq, count = struct.unpack_from('<2I', packet, cursor)
        cursor += 8
        result = {}
        for unused in range(count):
            values = struct.unpack_from('<5I', packet, cursor)
            cursor += 20
            label = read_text()
            for unused_item in range(values[4]): read_text()
            result[label] = values
        if cursor != len(packet): raise ValueError('request update is incomplete')
        return seq, result
    seq, current = snapshot(data)
    assert current['保存原件'][1:4] == (6, 1, 1), current
    assert current['保存副本'][1:4] == (6, 1, 0), current
    assert current['包含参考'][1:4] == (3, 1, 0), current
    for label in [None, '保存副本', '保存原件', '保存副本', '包含参考', '副本模式', '原始模式', '副本模式']:
        print('native control event:', label, 'sequence:', seq + 1, file=sys.stderr, flush=True)
        control = current[label][0] if label else 0
        event = struct.pack('<8I', magic, version, 3 if label else 4, 0, 0, control, 0, seq + 1)
        response.write_bytes(event + (strings[2] + '\0').encode('utf-16le'))
        deadline = time.monotonic() + 10
        while time.monotonic() < deadline:
            packet = request.read_bytes()
            try: next_seq, next_controls = snapshot(packet)
            except (struct.error, IndexError, ValueError): time.sleep(.02); continue
            if next_seq == seq + 1: break
            time.sleep(.02)
        else: raise AssertionError('control notification was not acknowledged')
        seq, current = next_seq, next_controls
        print('native control acknowledged:', label, file=sys.stderr, flush=True)
        if label is None:
            assert current['原始模式'][1:4] == (6, 1, 1), current
            assert current['副本模式'][1:4] == (6, 1, 0), current
            continue
        assert current[label][3] == 1, (label, current)
        if label in ['保存原件', '保存副本']:
            other = '保存原件' if label == '保存副本' else '保存副本'
            assert current[other][3] == 0, current
        if label in ['原始模式', '副本模式']:
            other = '原始模式' if label == '副本模式' else '副本模式'
            assert current[other][3] == 0 and current['独立选项'][3] == 1, current
else:
    assert controls == 0 and offset + 8 == len(data)
fixtures = pathlib.Path(os.environ['MACSW_PANEL_FIXTURES'])
paths = [fixtures / ('新模型.step' if mode == 2 else '模型一.SLDPRT')]
if case == 'multi':
    assert flags & 1
    paths.append(fixtures / '模型二.SLDPRT')
if case == 'cancel': paths = []
if case == 'com-save-fallback': paths = []
status = 2 if case == 'com-save-fallback' else (1 if case == 'cancel' else 0)
payload = struct.pack('<5I', magic, version, status, 2, len(paths))
payload += b''.join((str(p) + '\0').encode('utf-16le') for p in paths)
response.write_bytes(payload)
pathlib.Path(os.environ['MACSW_PANEL_CAPTURE']).write_text(json.dumps(strings, ensure_ascii=False))
''')
        helper.chmod(0o700)
        env = dict(os.environ, WINEPREFIX=str(root / 'bottle'), WINEDEBUG='-all',
                   WINELOADER=str(wine / 'lib/wine/x86_64-unix/MacSW'), WINESERVER=str(wine / 'bin/wineserver'))
        results = []
        try:
            subprocess.run([str(wine / 'bin/wine'), r'C:\windows\system32\wineboot.exe', '-u'],
                           env=env, check=True, timeout=120, capture_output=True)
            for arch, folder in [('x86_64', 'system32'), ('i686', 'syswow64')]:
                # Same-version builtins must be replaced explicitly for this fixture too.
                source = wine / 'lib/wine' / ('x86_64-windows' if arch == 'x86_64' else 'i386-windows') / 'comdlg32.dll'
                target = root / 'bottle/drive_c/windows' / folder / 'comdlg32.dll'
                if target.exists() or target.is_symlink(): target.unlink()
                target.write_bytes(source.read_bytes())
            env['MACSW_NATIVE_FILE_PANEL'] = str(helper)
            env['MACSW_PANEL_FIXTURES'] = str(fixtures)
            for arch in ['x86_64', 'i686']:
                for case, mode in [('open', 'open'), ('save', 'save'), ('multi', 'multi'),
                                   ('small', 'small'), ('cancel', 'open'), ('com-open', 'com'),
                                   ('com-save', 'com-save'), ('com-save-wildcard', 'com-save-wildcard'),
                                   ('com-save-controls', 'com-save-controls'),
                                   ('com-save-fallback', 'com-save-fallback')]:
                    if args.cases and case not in args.cases:
                        continue
                    print(arch, case, 'starting', flush=True)
                    env['MACSW_PANEL_CASE'] = case
                    capture = args.evidence / (arch + '-' + case + '-request.json')
                    env['MACSW_PANEL_CAPTURE'] = str(capture.resolve())
                    probe = PROJECT / 'build/native' / ('wine_file_panel_probe-' + arch + '.exe')
                    try:
                        run = subprocess.run([str(wine / 'bin/wine'), str(probe), mode], env=env,
                                             capture_output=True, timeout=40)
                    except subprocess.TimeoutExpired as error:
                        (args.evidence / (arch + '-' + case + '.log')).write_bytes(
                            (error.stdout or b'') + (error.stderr or b''))
                        raise
                    output = run.stdout.decode('utf-8', errors='replace')
                    (args.evidence / (arch + '-' + case + '.log')).write_bytes(run.stdout + run.stderr)
                    assert run.returncode == 0 and capture.exists(), (arch, case, output)
                    if case == 'small': assert 'ok=0 error=12291' in output, output
                    elif case == 'cancel': assert 'ok=0 error=0' in output, output
                    elif case == 'com-save-fallback':
                        assert 'hr=800704c7' in output and 'dialog_show_events=1' in output, output
                    else:
                        assert ('hr=00000000' if case.startswith('com-') else 'ok=1 error=0') in output, output
                        assert 'index=2' in output, output
                        if case.startswith('com-'): assert 'dialog_show_events=0' in output, output
                        if 'save' not in case: assert '模型一.SLDPRT' in output, output
                        else: assert '新模型.step' in output, output
                        if case == 'multi': assert '模型二.SLDPRT' in output, output
                        if case == 'com-save-controls': assert 'selected=12 checked=1' in output, output
                    results.append({'arch': arch, 'case': case, 'passed': True})
                    print(arch, case, 'passed', flush=True)
        finally:
            subprocess.run([str(wine / 'bin/wineserver'), '-k'], env=env, timeout=15, capture_output=True)
            subprocess.run([str(wine / 'bin/wineserver'), '-w'], env=env, timeout=15, capture_output=True)
        (args.evidence / 'result.json').write_text(json.dumps(results, indent=2))


if __name__ == '__main__':
    main()
