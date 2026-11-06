# SWCLI MCP host integration — 2026-11-06

## Current source integration — SWCLI v0.2.1

The development App sources pin the SWCLI v0.2.1 tag source commit
`60c6f463560b2541a17f91e0d6c5d84fe317b8bd`. The executable command is `swcli`.
The five MCP tools are `status`, `daemon_start`, `daemon_stop`, `capabilities`
and `execute`; the former `swcli_`-prefixed names are not the current contract.
MacSW's own skill uses these names, and packaging copies the matching upstream
MCP guide from the pinned source. App verification compares that guide byte for
byte with the packaged SWCLI copy.

`Contents/MacOS/swcli` resolves the App, sets native Python/path/endpoint
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

SWCLI v0.2.1 adds `--tray auto|on|off` to daemon start/serve/restart and the
corresponding `tray` argument to MCP `daemon_start`. The default `auto` enables
the Windows notification icon on native Windows and leaves it off under Wine.
It is independent of `visible`, which controls a newly owned SOLIDWORKS window;
reusing an existing daemon does not change either setting. This Windows icon is
separate from MacSW's native menu-bar controller. Hiding the icon leaves SW and
the daemon running, while its stop action uses the same document/ownership guards.

MCP 1.30.0 and 22 additional dependencies are included only in native Python,
using exact wheel hashes/URLs in the existing offline manifest. Windows Python
continues to run the daemon/COM worker without the SDK. The packaged MacSW skill
links the source-pinned MCP guide, and App verification imports the native SDK
without activating SW or starting a listener.

## v0.2.1 packaged runtime acceptance

The 0.2.0/build14 local candidate passes packaging and strict ad-hoc signature
verification. Its native MCP client/SDK reached a real Wine SW33.5.0 host in an
independent cloned bottle at port18921. Discovery returned the five short tools;
status while stopped did not start SW. Explicit startup, capability discovery,
empty document enumeration, retained ownership/PID after disconnect/reconnect,
and explicit shutdown all passed. MCP stayed alive for ping after shutdown. An
immediate shutdown-race observation returned explicit unknown on connection
reset; a later read-only query confirmed stopped. No formal user host was altered.
This does not establish Developer ID signing, notarization or final CI success.

## Historical a16 integration evidence

The following checks belong to the initial source integration at
`1354a6c5126243c50369451ef5477e0beab41b2c` (version string 0.1.0a16), separate
from the original published a16 artifacts. No App was built, installed or
launched in that initial source-only change. They do not establish v0.2.1 App
or runtime acceptance.

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

For that historical a16 integration, MacSW CI, App signing/build/install and
native Wine SOLIDWORKS activation were not run. Its source-level integration and
offline SDK checks do not claim those results or verify the current v0.2.1 candidate.
