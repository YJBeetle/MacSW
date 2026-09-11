# Mono interpreter upstream validation

## Scope

This investigation concerns x86 Windows P/Invoke calling conventions in the
Mono interpreter. It does not establish a defect on every Mono platform.
The separate macOS x86 JIT startup hang is not fixed by this patch.

## Linux Wine reproduction

Host: Debian 13 x86_64. Wine: Debian 10.0~repack-6, with amd64 and i386
packages. Tests use an independent prefix and Xvfb on 10.24.11.1.
No SOLIDWORKS files or license configuration are involved.

Both engines were built by GitHub CI from the Wine Mono 11.3.0 baseline.

| Engine | Interpreter cdecl | Interpreter stdcall | JIT cdecl | JIT stdcall |
| --- | --- | --- | --- | --- |
| Unmodified baseline | Pass | Native crash | Pass | Pass |
| Candidate v4 | Pass | Pass | Pass | Pass |

Successful native calls returned -1 and the process exited with code 0.
The baseline interpreter stdcall call faulted while executing address
0x028a0080; the crash debugger was then stopped by the harness timeout
(exit 124). This is a crash followed by timeout, not an unexplained hang.

Baseline DLL SHA-256:
`003255a0ef2a59d47e2052abb883d9925a206a534ee4bcbe8ab8786de5bd3d7b`

Candidate DLL SHA-256:
`1541b5f189664e7f3d09d7e5ee5c3ae9e1c19534b79e8331fb9a51f9c1c21562`

Local raw logs: `scratch/linux-mono-results/`.
Remote scripts and logs: `/home/YJBeetle/macsw-mono-repro/`.

## Proposed upstream coverage

The fork adds pointer-return P/Invoke coverage to the existing `pinvoke2.cs`
and `libtest.c` framework. It interleaves cdecl, explicit stdcall, and default
Winapi calls repeatedly. CI 34614333278 ran the test successfully under
both the candidate interpreter and JIT. CI 34615947382 then ran the same
test binary and class libraries with the official 11.3.0 release engine
and the candidate: the release interpreter crashed after entering the
test, whereas release JIT and both candidate modes reported one test and
zero failures. The matrix above remains the independent bridge result.

Before opening a PR:

- Preserve the completed baseline/candidate CI evidence and rerun it after
  any implementation changes.
- Add broader argument-count and return-type coverage for the new dispatch.
- Review normalized signature ownership and wrapper selection.
- Consolidate exploratory implementation commits, excluding the transient
  signature lifetime bug introduced by candidate v3.
- Keep the macOS JIT issue separate and state host/runtime coverage precisely.

No upstream PR has been opened.
