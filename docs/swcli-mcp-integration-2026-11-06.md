# SWCLI MCP host integration — 2026-11-06

The development App sources pin SWCLI 1354a6c5126243c50369451ef5477e0beab41b2c
(version string 0.1.0a16). This source increment is separate from the original
published a16 artifacts. No App was built, installed or launched for this change.

`Contents/MacOS/sw-cli` resolves the App, sets native Python/path/endpoint
configuration and `SWCLI_DAEMON_UTILS`, and forwards all public arguments.
Python parses options once, including leading global options. The separate
`Contents/Resources/SWCLI/bin/swcli-daemon-utils` receives an explicit action
and invokes Wine Windows Python with the existing compatibility profile,
runtime synchronization, mapped paths and windowless lifecycle output.
`start`, `restart`, `serve` and `doctor` are host actions; status/stop use the
native TCP client without entering Wine. A backend marker prevents recursion.
The utilities do not implement a second service or persist lifecycle state.

The manager and MCP adapter use explicit startup, with readiness/latency guidance;
there is no lazy startup. MCP disconnect retains the host. The agent can use the
explicit stop tool according to user preferences and task needs; the original
open-document and attached-host ownership guards remain authoritative.
Independent multi-instance support is deferred; no force-new option was added.

MCP 1.30.0 and 22 additional dependencies are included only in native Python,
using exact wheel hashes/URLs in the existing offline manifest. Windows Python
continues to run the daemon/COM worker without the SDK. The packaged MacSW skill
links the source-pinned MCP guide, and App verification imports the native SDK
without activating SW or starting a listener.

## Local evidence

- Exact standalone native Python 3.11.16 archive checksum verified.
- Actual SDK stdio/session/progress/error tests: 16 passed; manager tests: 19 passed.
- Original dependency-packaging helper executed with all real locked wheels in
  a temporary fixture; native imports succeeded and Windows output had no SDK.
- Fake-runtime launcher test passed: native forwarding, utility action routing,
  custom overrides, leading options, symlink/App paths, Wine preflight/sync
  failure propagation and literal path arguments. No real Wine was launched.
- Related SWCLI packaging/runtime tests: 31 passed. AI connection contracts:
  6 passed. Cache identity checks: 27 passed. Skill and Bash checks passed.
- SWCLI full portable suite: 1598 tests, 21 platform skips. Its separate original
  Windows receipt proves native hidden ownership, open-document stop refusal,
  retention after MCP disconnect and final explicit shutdown; native backend
  and MCP files were byte-compared across the utilities refactor.

MacSW CI, App signing/build/install, and native Wine SOLIDWORKS activation were
not run. Source-level integration and offline SDK tests do not claim those results.
