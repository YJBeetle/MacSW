# Finder integration

MacSW sets `MACSW_NATIVE_FILE_MANAGER=1` for GUI, CLI and runtime-maintenance Wine launches.
Patch `0016-shell-native-file-manager.patch` handles filesystem folder arguments to
`explorer.exe` with `/usr/bin/open -a Finder`, and `/select,PATH` with `open -R`.
`SHOpenFolderAndSelectItems` also supports a single filesystem item, including
relative child PIDLs. Windows paths are resolved by Wine's own drive mappings,
including C:, Z:, custom drives and mapped network paths.

Native launches use an argument array and an explicit `--`, without a command
shell or interpolated AppleScript. Missing or unmappable targets and native
launch failures retain Wine's behavior. Virtual shell objects, edit requests and
multiple selections retain the Wine Explorer selection protocol. Explicit `/e,`
and `/desktop` requests continue to use Wine Explorer. Without the opt-in
environment variable the patch does not redirect anything.

Both x86 and x64 shell32/explorer binaries are built, packaged and bound into the
runtime identity; existing bottles must complete the normal container upgrade
to receive updated builtin modules. Do not overwrite an installed signed App's
contents to test this patch.

The upgrade stops the prefix after `wineboot -u` and atomically copies the
verified shell32/explorer modules into system32/syswow64 (plus the Windows-root
Explorer alias). This is necessary because wineboot can keep builtin files
whose Wine version is unchanged. Only then do the normal dependency checks run.

## Optional UI probe

Build `bash scripts/build_wine_file_manager_probe.sh`. In a disposable Wine
prefix with the patched modules, set `MACSW_NATIVE_FILE_MANAGER=1` and run the
matching `wine_file_manager_probe-{x86_64,i686}.exe` with:

- `folder DIRECTORY`: open the directory in Finder.
- `select FILE`: reveal through Explorer's `/select,` syntax.
- `api FILE`: reveal through `SHOpenFolderAndSelectItems(FILE, 0, ...)`.
- `child FILE`: reveal through a relative child PIDL.
- `absolute FILE`: cover Wine's existing absolute-child compatibility.

The probe reports API/launcher success. Finder's visible folder or selection must
also be verified before claiming GUI acceptance. Include Chinese, spaces, commas
and shell metacharacters in fixture names; no command substitution should occur.

Local validation on 2026-10-27 compiled both architectures and passed eight
Wine API/Explorer launch cases. An existing disposable prefix also received all
four binaries through the explicit deployment path after wineboot retained its
old same-version modules. The user confirmed, with a screenshot, Finder opening
the demo directory and selecting `Finder 定位验证.txt`. This validates the
temporary runtime; it does not claim that the installed signed App was replaced.
