---
name: macsw
description: Use MacSW's SWCLI for SOLIDWORKS CAD work on macOS, including checking the current SW document, inspecting or editing models, and opening, importing, rendering or exporting .SLDPRT, .SLDASM, .SLDDRW and CAD .STEP/.STP files. Use for assemblies, motion studies and exploded views, including requests such as “看下 SW” in a CAD context.
---

# MacSW

1. Read `references/local-connection.md` if present. Use its recorded MacSW launcher and container/endpoint. If it is absent, use `/Applications/MacSW.app/Contents/MacOS/sw-cli` with its defaults. If the recorded installation moved or no longer matches the target, re-establish the connection before acting.
2. Check `version --json`, `daemon status --json` and `capabilities --json`. Use the same connection for subsequent commands. Require a successful status with `result.host_connected=true`, `result.worker_alive=true`, `result.recovery_required=false` and a non-null `result.host` before CAD operations. Request `capabilities --operation NAME --json` for the operation contract. A failed request does not establish that a document or feature is absent.
3. For “current file”, start with `document inspect --document active --json`. For a named file, use `document list --json` to identify an already-open document. Match paths and use explicit document IDs for multi-document work. Open or import only as needed, with read-only access where supported for inspection. Use the launcher's native path translation rather than assuming a `Z:` mapping.
4. Use the advertised typed command where it covers the task. Read [the bundled usage guide](references/usage.md) for request schemas, document targeting, leases, geometry and export workflows. Inspect native state before editing and verify the actual result before reporting success. If a command fails after starting an edit, inspect for partial changes before any retry.

If the daemon is unavailable, ask the user to start or recover it from the MacSW menu and recheck status. Typed document commands do not start a daemon implicitly. With explicit lifecycle authorization, use `--attach-existing` to share a running instance. For an existing daemon with a disconnected host, recovery uses `daemon restart`, subject to the same authorization. Keep unsaved documents and existing instances intact. If process or approval checks block a lifecycle action, stop and use the menu or the normal approval mechanism.

## When the CLI has a coverage gap

If the capability catalog confirms the needed operation is missing or its documented scope excludes the task, continue with the [official SOLIDWORKS API workflow](references/solidworks-api.md). The bundled usage guide describes the typed CLI boundary. Use this separate route only for the uncovered capability. A timeout, access refusal, stale handle, document lease conflict, or failed typed operation must be diagnosed through its own path.
