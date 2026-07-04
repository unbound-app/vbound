# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

vbound is a macOS SwiftUI companion app for developing [Unbound](https://github.com/unbound-app/loader-ios) (a Discord jailbreak tweak) against a `vphone` virtual iOS device. It's a single fixed-size (600×505), non-resizable, floating-level window that snaps beside the vphone window and drives the whole dev loop — boot the device, build/install the tweak over SSH, stream its logs, and get an SSH shell — without leaving the keyboard.

Requires `vphone-cli`, `pymobiledevice3` (`pipx install pymobiledevice3`), and `sshpass` (`brew install sshpass`) on the host. See README.md for the full requirements/usage table.

## Commands

- **Build/run**: open `vbound.xcodeproj` in Xcode 26+, select a signing team, ⌘R. No external build tools needed for local dev.
- **CLI build**: `xcodebuild -project vbound.xcodeproj -scheme vbound -configuration Debug -destination 'platform=macOS' build`
- There is no test target — verify changes by building and actually running the app (attach to a real or simulated vphone where possible).
- CI: `.github/workflows/main.yml` runs an unsigned Debug build on every push/PR (`CODE_SIGNING_ALLOWED=NO`), then on push to `main` checks whether `MARKETING_VERSION` in `project.pbxproj` was bumped; if so it calls `release.yml`, which archives, notarizes, publishes a GitHub release, and attaches a `.sha256` checksum. Both workflows cache SPM checkouts via `-clonedSourcePackagesDirPath SourcePackages` + `actions/cache`.

## Architecture

### File layout

- `vbound/ContentView.swift` — all main-window SwiftUI: status strip (Boot/Stop/Discord/Build/Settings), Logs tab (Unbound/React Native/Shell sub-tabs, filter bar, log rows), Shell tab (SSH terminal UI)
- `vbound/AppController.swift` + `AppController+{Build,Device,LogStream,Process,Shell}.swift` — one `@Observable @unchecked Sendable` class, split into extensions by concern. `AppController.swift` itself only holds window-attachment logic (CGWindowList polling) and shared state/lifecycle; each extension owns one subsystem.
- `vbound/SettingsView.swift` — the `Settings` scene: a 3-tab `TabView` (General: paths/SSH password; Automation: auto-attach/auto-start-stream/auto-connect-shell; Advanced: update checking, log/shell buffer sizes), all backed by `@AppStorage`, plus a "Reset to Defaults" action that clears just those keys.
- `vbound/UpdateSheet.swift` — in-window update overlay (not a system `.sheet`) built on the `AppUpdater` package.
- `vbound/Components/` — `FolderPicker` (path picker with a git-repo validity dot), `LevelFilter` (reused for both the INF/ERR/DBG toggle chips *and* the MERGE chip), `LogTextView` (NSViewRepresentable log renderer — see below), `JSONHighlighter` (syntax highlighter for JSON popovers shown in the update sheet's changelog — *not* used by the log view; log "structured data" detection is NSObject/ObjC-description-only, see below), `WindowAccessor` (bridges the SwiftUI window to the underlying `NSWindow` for one-time setup).
- `vbound/Models.swift` — `LogEntry`, `LogSubsystem`, `BuildPhase`, and `ANSILineBuffer` (parses incoming shell bytes into SGR-colored `ShellLine`s).

### Window attachment

`AppController` polls `CGWindowListCopyWindowInfo` every 100ms to find the vphone window (matched by owning process name or window title containing "vphone") and snaps the panel to its right edge (`positionBeside`). The Y-coordinate flip uses `NSScreen.screens.first` (the primary display) — **not** `NSScreen.main`, which is whichever screen currently holds the key window. `CGWindowList` bounds are always relative to the primary display, so using `.main` there mispositions the panel on multi-monitor setups whenever vbound and vphone are focused on different screens. The panel runs at `.floating` level so it stays above vphone, but that would also cover ordinary windows (Settings, About, alerts) — `AppController.swift`'s `didBecomeKeyNotification`/`willCloseNotification` observers temporarily drop it to `.normal` whenever another window is key, restoring `.floating` once nothing else is open. Auto-start (log stream / shell) is gated through a one-shot `markAttached()` guarded by `isAttached` so it fires exactly once per attach transition, not every 100ms poll tick. Closing the window quits the whole app (`TerminatingWindowDelegate` in `vboundApp.swift` intercepts the close button/`windowShouldClose` and routes through confirmation alerts if a build is running or vbound booted vphone itself); the Stop button's shutdown confirmation carries the same build-in-progress warning.

### Log streaming

`AppController+LogStream.swift` runs `pymobiledevice3 syslog live --udid <id> --format json` as a **persistent** process (`Pipe` + `readabilityHandler`, not polling) and filters for the `app.unbound` / `com.facebook.react.log` subsystems **in-process** — the CLI's own `--match`/`--regex` filters are documented as ignored in JSON output mode, so subsystem filtering has to happen in Swift. Do not switch this back to `pymobiledevice3 syslog collect` + `log show --archive <path>`: that archive-based approach silently returns zero events on some pymobiledevice3/iOS combinations even though the device is actively logging — this is what broke the entire Logs tab once already.

`startLogStream()`/`connectShell()` are thin public wrappers that clear `logLines`/`shellLines` once and then call an internal `beginLogStreamTask()`/`beginShellConnection()`; auto-reconnect (`logStreamAutoReconnect`/`shellAutoReconnect`) re-enters through the internal function directly so a transient drop doesn't wipe the scrollback you were looking at — only an explicit user-initiated Stream/Connect click does. Reconnects print `">> reconnected to vphone <udid>"` instead of repeating the initial `">> streaming from"` banner, so a flapping connection is visible in the (now-preserved) history. Both `stopLogStream()`/`disconnectShell()` clear the auto-reconnect flag first — `shutdownVphone()` and `AppController.stop()` both call these *before* tearing anything down, otherwise the device going offline intentionally would just trigger a retry-every-2-seconds loop against a device that's no longer there.

The device UDID is resolved via `pymobiledevice3 usbmux list` JSON, matched on `ProductType == "iPhone99,11"` (vphone's fixed product type), and cached on `AppController.vphoneUDID` — reuse that cache instead of re-probing when an action (e.g. shutdown) just needs the UDID and doesn't need to re-discover the device. Unlike the SSH-based calls (which get `-o ConnectTimeout=5`), raw `pymobiledevice3` invocations have no built-in timeout — `run(args:timeout:)`/`runCapture(args:timeout:)` support an optional timeout that terminates the process if it hangs; `usbmux list` and `diagnostics shutdown` both pass one.

### Shell tab

`AppController+Shell.swift` maintains a second persistent process: `sshpass ... ssh -tt -p 2222 mobile@127.0.0.1`, read the same `Pipe`+`readabilityHandler` way. Output bytes are fed through `Models.swift`'s `ANSILineBuffer`, which tracks SGR color/bold escape codes and drops non-SGR CSI sequences (cursor movement, bracketed-paste mode, etc.) rather than attempting full terminal emulation — so anything that redraws in place (`vim`, `nano`, `htop`) won't render correctly here.

### Build pipeline

`AppController+Build.swift`: `gmake package DEBUG=1` (falls back through Homebrew/`/usr/bin/make` paths) in the configured Unbound source directory, `scp` the resulting `.deb` to the device over the same port-forwarded SSH, `dpkg -i` it via `sudo`, then calls the shared `restartDiscord()` (also used by the standalone "Launch Discord" action) to load the fresh tweak. `findDeb(in:)` picks the *most recently modified* `.deb` in `packages/`, not just whatever `contentsOfDirectory` lists first — that directory isn't necessarily cleaned between builds, so an unsorted pick could silently upload a stale package. Progress is estimated by counting `.x`/`.xm`/`.m`/`.mm`/`.swift` source files up front, not by parsing real compiler progress.

### SSH / port forwarding

Everything SSH-related targets `mobile@127.0.0.1:2222` (`pymobiledevice3 usbmux forward 2222 22`, brought up on demand by `ensurePortForward()`), authenticated with `sshpass` using the password from Settings (`AppStorage("sshPassword")`, defaults to vphone's stock `alpine`). An SSH `ControlMaster`/`ControlPath` mux (`AppController.sshControlPath`, under `~/.ssh/vbound-mux`) is shared across build/shell/shutdown so repeated commands don't each pay the SSH handshake cost.

### Custom SF Symbols — a real gotcha

Three custom symbols (`Unbound`, `React Native`, `Discord`) live in `Assets.xcassets` as symbolsets. **`Image(systemName:)` / `NSImage(systemSymbolName:)` cannot load them** — that API only resolves Apple's own system symbol catalog, even though the custom symbols compile into `Assets.car` correctly and look identical to system ones in the asset catalog. They must be referenced with plain `Image("Unbound")` (i.e. `NSImage(named:)`) instead. `ContentView.swift`'s `tabLabel` branches on a `customSymbolNames` set to pick the right initializer per icon name. The merged-logs tab (toggled by the MERGE chip, not a separate tab) composites the Unbound and React Native marks side by side with a small "+" via a dedicated `mergedLogsIcon` view rather than either single symbol.

### Concurrency model

The project builds with `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`, so every type/method is implicitly MainActor-isolated unless marked `nonisolated`. `AppController` is additionally declared `@unchecked Sendable` because its `Process`/`Pipe` `readabilityHandler` closures run on background queues and need to touch its state. The established pattern for that boundary: do the actual `self.someObservableProperty = ...` mutation inside `DispatchQueue.main.async { MainActor.assumeIsolated { ... } }` (see `AppController+Shell.swift`, `AppController+LogStream.swift`); a captured local `var` mutated directly inside a background closure is what Swift 6 flags as unsafe, not a stored property reached through an isolation hop like this. Pure helper functions with no actor-isolated state (e.g. `AppController+LogStream.swift`'s `parseLiveSyslogLine`) are marked `nonisolated static` so they can run directly on the background thread without paying a main-actor hop per call.

### Updates

`vboundApp.swift` wires an `AppUpdater` (GitHub releases for `unbound-app/vbound`) checked on an interval from Settings; in `DEBUG` builds it's pointed at `vbound/releases.mock.json` via a `MockReleaseProvider` instead of hitting the network. The check loop polls every 60 seconds and compares accumulated elapsed time against the *current* `updateCheckIntervalHours` rather than doing one long `Task.sleep` for the whole interval — otherwise changing the interval in Settings wouldn't take effect until whatever multi-hour sleep was already in flight happened to finish. `UpdateSheet.swift` renders the flow as an in-window overlay rather than a system sheet — a real `NSWindow` sheet on this floating, non-resizable panel repaints incorrectly while its content resizes across states.

### Sandbox

`ENABLE_APP_SANDBOX = NO` — required because the app shells out directly to `sshpass`, `ssh`, `scp`, and `pymobiledevice3` via `Process`, which the sandbox would block.
