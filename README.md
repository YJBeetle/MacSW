# MacSW

**English** | [简体中文](README.cn.md)

A standalone macOS app for installing, running, and maintaining SOLIDWORKS on
Apple Silicon Macs. MacSW bundles pinned Wine, compatibility fixes, and
[SWCLI](https://github.com/YJBeetle/SWCLI) in `MacSW.app`, with guided installation,
a menu bar launcher, and command-line automation. A built App does not require
the source checkout, Homebrew, a separately installed Python, or external launch scripts.

MacSW is an independent project. It is not affiliated with, endorsed by, or
supported by Dassault Systèmes or SOLIDWORKS. It does not provide SOLIDWORKS
installation media or licenses, or a product feature for modifying its official program files.

## Requirements and verification scope

- An Apple Silicon Mac and Rosetta 2 for the bundled x86_64 Wine runtime.
- The App deployment target is macOS 13; see the [compatibility reports](docs/compatibility.md)
  for the systems and features actually tested.
- Your own official SOLIDWORKS installation media and applicable license configuration.
- Disk space for the App, installation bottle, and installation process. Back up bottle contents before reinstalling.

This is a development test package with ad-hoc signing, not Developer ID signing
or notarization. SOLIDWORKS 2025 SP5.0 installation, the main window, and some
interactions have been verified on real hardware; this does not establish support
for every component, add-in, or modeling workflow. Bundled SWCLI is pinned to a
development snapshot, not a claim that this version has been formally released.
Successful installation, startup, and complete automation tests are separate
results. See the [compatibility reports](docs/compatibility.md) and
[real-runtime CI documentation](docs/runtime-ci.md) for their respective evidence.

## Installation and use

**Back up before reinstalling: a clean installation clears MacSW's sole bottle, including models stored inside it.**

1. Download the App archive from the `MacSW-macOS-App` artifact of a
   [GitHub Actions build](https://github.com/YJBeetle/MacSW/actions/workflows/build-app.yml).
   Extract it and place `MacSW.app` in your applications directory.
   Alternatively, [build from source](#building-from-source).
2. Open the App. If SOLIDWORKS is not installed, the installation window appears.
3. Drag in or select official media: an ISO, `setup.exe`, or a directory containing the installer.
4. Confirm component serial numbers, UI language, and license server configuration,
   then start installation. Deployment is silent by default; settings allow using the official installer wizard instead.
5. Once installed, launch SOLIDWORKS from the MacSW menu bar icon.

Opening MacSW **does not launch SOLIDWORKS automatically** by default; enable that
option in settings if desired. Settings also provide Wine tools, license server
addresses, and installation, removal, start, and stop controls for managed FlexNet.
A managed server is copied into the bottle and no longer depends on the original
external directory. Before launching SOLIDWORKS, MacSW ensures the required local
managed service is running according to the current license configuration.

Chinese UI fallback uses macOS PingFang to supply missing glyphs; Apple fonts are
not bundled. Opening MacSW starts a background check of the installed bottle's
Tahoma font links, repairs missing links while preserving existing fallbacks,
and shares that preparation task with subsequent SOLIDWORKS launches.
See the [font documentation](docs/font-fallback.md).

## SWCLI quick start

The bundled `sw-cli` provides document and part automation. **Start the daemon
before document operations**: `document` and `part` commands do not implicitly launch SOLIDWORKS.

Choose **Copy AI connection info** (复制 AI 接入信息) in the menu bar panel, between
the SOLIDWORKS action and the logs action. Share the text with an agent that can
read local files and run terminal commands. It contains the current App, CLI,
complete skill, guide, bottle and endpoint paths/configuration. The agent handles
skill installation using its own mechanism and your authorization; MacSW does
not change agent settings. Copying runs no discovery commands, starts no Wine or
SOLIDWORKS, creates no bottle, and does not establish daemon readiness.

These examples assume `/Applications/MacSW.app`; change the first line for another location.

```bash
SWCLI="/Applications/MacSW.app/Contents/MacOS/sw-cli"

# SOLIDWORKS is not running: create a visible instance; omit --visible for hidden mode
"$SWCLI" daemon start --visible --json

# The start command waits for host readiness before document operations
"$SWCLI" document list --json
```

If SOLIDWORKS was already launched by MacSW, use this start command instead to
attach to its existing window without creating a second instance:

```bash
"$SWCLI" daemon start --attach-existing --json
```

Without a daemon, document and part commands return `DaemonUnavailable` and
startup guidance. Local paths are translated using the bottle's actual drive
mappings; Z: is not assumed, and an unmapped path fails explicitly. Access models
inside `drive_c` through their corresponding C: paths, not Z: aliases.
See the [SWCLI documentation](Dependencies/SWCLI/README.md) for commands and the protocol.

## Data and troubleshooting

MacSW uses one fixed bottle, with no bottle-switching feature:

```text
~/Library/Application Support/MacSW/bottle
~/Library/Application Support/MacSW/logs
```

**A clean installation clears the sole bottle.** Back up models and other files you need to retain first.

For installation failures, start with `install_msi_errors.log`, `install_msi.log`,
and `prerequisites.log`; for launch issues, inspect `sw_launch.log`. Login Manager,
language installation, and the Wine installer also have separate logs.
When reporting an issue, include the MacSW build, macOS/chip, SOLIDWORKS version,
whether the bottle was fresh, and reproduction steps.

**Do not publish full logs or bottles without review.** Detailed MSI logs may
contain plaintext serial numbers. Remove serial numbers, license files,
credentials, user names, and private paths before sharing. Keep the log directory private.

## Building from source

Development builds require a macOS toolchain/SDK supporting Swift 5.10,
Xcode Command Line Tools, and Homebrew. Check out the source and submodules, then run:

```bash
git clone --recurse-submodules https://github.com/YJBeetle/MacSW.git
cd MacSW
brew install bison mingw-w64
make app
```

The output is `build/app/MacSW.app`. The first build downloads and verifies pinned
dependencies; later builds reuse the `dist/` cache. See the
[development guide](docs/development.md) for tests, packaging, installer internals,
and Wine fixes. GitHub Actions runs `make test` and `make archive` as separate steps
in the `build` job. An independent `runtime-test` job downloads this run's App and
performs isolated real installation/runtime validation without recompiling it.
Relevant master pushes in this repository run automatically; manual triggering is
also supported. PRs do not access private runtime resources.

## Documentation

Some detailed implementation notes and reports are written in Chinese.

- [Development and builds](docs/development.md)
- [Compatibility and tested scope](docs/compatibility.md)
- [Real installation and runtime CI](docs/runtime-ci.md)
- [Chinese font fallback](docs/font-fallback.md)
- [Viewport layer clipping](docs/winemac-opengl-child-clipping.md)
- [OpenGL front-buffer and preselection fixes](docs/opengl-front-buffer.md)
- [Chinese IME and model-view shortcuts](docs/solidworks-space-ime.md)
- [SWCLI](Dependencies/SWCLI/README.md)

## License

Original MacSW code is licensed under the [Apache License 2.0](LICENSE). Wine and
[patches](patches/wine-crossover) directly modifying or derived from Wine remain
LGPL-2.1-or-later; third-party components retain their respective licenses.
Binary distributions include the corresponding licenses, notices, and exact Wine source information.

See [NOTICE](NOTICE) for project name, logo, other identifier ownership, and
third-party notices. Apache-2.0 does not grant branding rights to present a
modified or redistributed version as an official MacSW release.
