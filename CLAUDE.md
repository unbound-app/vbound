# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

vbound is a macOS SwiftUI companion app for developing [Unbound](https://github.com/unbound-app/loader-ios) (a Discord jailbreak tweak) against a `vphone` virtual iOS device. It's a single fixed-size (600×505), non-resizable, floating-level window that snaps beside the vphone window and drives the whole dev loop — boot the device, build/install the tweak over SSH, stream its logs, and get an SSH shell — without leaving the keyboard.

Requires `vphone-cli`, `pymobiledevice3` (`pipx install pymobiledevice3`), and `sshpass` (`brew install sshpass`) on the host. See README.md for the full requirements/usage table.

## Commands

- **Build/run**: open `vbound.xcodeproj` in Xcode 26+, select a signing team, ⌘R. No external build tools needed for local dev.
- **CLI build**: `xcodebuild -project vbound.xcodeproj -scheme vbound -configuration Debug -destination 'platform=macOS' build`
- There is no test target — verify changes by building and actually running the app (attach to a real or simulated vphone where possible).
- CI (`.github/workflows/main.yml`) checks whether `MARKETING_VERSION` in `project.pbxproj` was bumped on push to `main`; if so it calls `release.yml`, which archives, notarizes, and publishes a GitHub release via `xcodebuild archive` / `-exportArchive`.

## Architecture

### File layout

- `vbound/ContentView.swift` — all main-window SwiftUI: status strip (Boot/Stop/Discord/Build/Settings), Logs tab (Unbound/React Native/Shell sub-tabs, filter bar, log rows), Shell tab (SSH terminal UI)
- `vbound/AppController.swift` + `AppController+{Build,Device,LogStream,Process,Shell}.swift` — one `@Observable @unchecked Sendable` class, split into extensions by concern. `AppController.swift` itself only holds window-attachment logic (CGWindowList polling) and shared state/lifecycle; each extension owns one subsystem.
- `vbound/SettingsView.swift` — the `Settings` scene (paths, SSH password, auto-attach, update check interval, log buffer size), all backed by `@AppStorage`.
- `vbound/UpdateSheet.swift` — in-window update overlay (not a system `.sheet`) built on the `AppUpdater` package.
- `vbound/Components/` — `FolderPicker` (path picker with a git-repo validity dot), `LevelFilter` (INF/ERR/DBG toggle chips), `LogTextView` (NSViewRepresentable log renderer — see below), `JSONHighlighter` (shared regex-based syntax highlighter used by `LogTextView`'s popovers), `WindowAccessor` (bridges the SwiftUI window to the underlying `NSWindow` for one-time setup).
- `vbound/Models.swift` — `LogEntry`, `LogSubsystem`, `BuildPhase`, and `ANSILineBuffer` (parses incoming shell bytes into SGR-colored `ShellLine`s).

### Window attachment

`AppController` polls `CGWindowListCopyWindowInfo` every 100ms to find the vphone window (matched by owning process name or window title containing "vphone") and snaps the panel to its right edge (`positionBeside`). The panel runs at `.floating` level so it stays above vphone, but that would also cover ordinary windows (Settings, About, alerts) — `AppController.swift`'s `didBecomeKeyNotification`/`willCloseNotification` observers temporarily drop it to `.normal` whenever another window is key, restoring `.floating` once nothing else is open. Closing the window quits the whole app (`TerminatingWindowDelegate` in `vboundApp.swift` intercepts the close button/`windowShouldClose` and routes through confirmation alerts if a build is running or vbound booted vphone itself).

### Log streaming

`AppController+LogStream.swift` runs `pymobiledevice3 syslog live --udid <id> --format json` as a **persistent** process (`Pipe` + `readabilityHandler`, not polling) and filters for the `app.unbound` / `com.facebook.react.log` subsystems **in-process** — the CLI's own `--match`/`--regex` filters are documented as ignored in JSON output mode, so subsystem filtering has to happen in Swift. Do not switch this back to `pymobiledevice3 syslog collect` + `log show --archive <path>`: that archive-based approach silently returns zero events on some pymobiledevice3/iOS combinations even though the device is actively logging — this is what broke the entire Logs tab once already.

The device UDID is resolved via `pymobiledevice3 usbmux list` JSON, matched on `ProductType == "iPhone99,11"` (vphone's fixed product type), and cached on `AppController.vphoneUDID` — reuse that cache instead of re-probing when an action (e.g. shutdown) just needs the UDID and doesn't need to re-discover the device.

### Shell tab

`AppController+Shell.swift` maintains a second persistent process: `sshpass ... ssh -tt -p 2222 mobile@127.0.0.1`, read the same `Pipe`+`readabilityHandler` way. Output bytes are fed through `Models.swift`'s `ANSILineBuffer`, which tracks SGR color/bold escape codes and drops non-SGR CSI sequences (cursor movement, bracketed-paste mode, etc.) rather than attempting full terminal emulation. Drops reconnect automatically (`shellAutoReconnect`) unless the user explicitly disconnected.

### Build pipeline

`AppController+Build.swift`: `gmake package DEBUG=1` (falls back through Homebrew/`/usr/bin/make` paths) in the configured Unbound source directory, `scp` the resulting `.deb` to the device over the same port-forwarded SSH, `dpkg -i` it via `sudo`, then kill and relaunch Discord to load the fresh tweak. Progress is estimated by counting `.x`/`.xm`/`.m`/`.mm`/`.swift` source files up front, not by parsing real compiler progress.

### SSH / port forwarding

Everything SSH-related targets `mobile@127.0.0.1:2222` (`pymobiledevice3 usbmux forward 2222 22`, brought up on demand by `ensurePortForward()`), authenticated with `sshpass` using the password from Settings (`AppStorage("sshPassword")`, defaults to vphone's stock `alpine`). An SSH `ControlMaster`/`ControlPath` mux (`AppController.sshControlPath`, under `~/.ssh/vbound-mux`) is shared across build/shell/shutdown so repeated commands don't each pay the SSH handshake cost.

### Custom SF Symbols — a real gotcha

Three custom symbols (`Unbound`, `React Native`, `Discord`) live in `Assets.xcassets` as symbolsets. **`Image(systemName:)` / `NSImage(systemSymbolName:)` cannot load them** — that API only resolves Apple's own system symbol catalog, even though the custom symbols compile into `Assets.car` correctly and look identical to system ones in the asset catalog. They must be referenced with plain `Image("Unbound")` (i.e. `NSImage(named:)`) instead. `ContentView.swift`'s `tabLabel` branches on a `customSymbolNames` set to pick the right initializer per icon name; the Shell tab's `terminal` icon is a real system symbol and still goes through `Image(systemName:)`.

### Concurrency model

The project builds with `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`, so every type/method is implicitly MainActor-isolated unless marked `nonisolated`. `AppController` is additionally declared `@unchecked Sendable` because its `Process`/`Pipe` `readabilityHandler` closures run on background queues and need to touch its state. The established pattern for that boundary: do the actual `self.someObservableProperty = ...` mutation inside `DispatchQueue.main.async { MainActor.assumeIsolated { ... } }` (see `AppController+Shell.swift`, `AppController+LogStream.swift`); a captured local `var` mutated directly inside a background closure is what Swift 6 flags as unsafe, not a stored property reached through an isolation hop like this. Pure helper functions with no actor-isolated state (e.g. `AppController+LogStream.swift`'s `parseLiveSyslogLine`) are marked `nonisolated static` so they can run directly on the background thread without paying a main-actor hop per call.

### Updates

`vboundApp.swift` wires an `AppUpdater` (GitHub releases for `unbound-app/vbound`) checked on an interval from Settings; in `DEBUG` builds it's pointed at `vbound/releases.mock.json` via a `MockReleaseProvider` instead of hitting the network. `UpdateSheet.swift` renders the flow as an in-window overlay rather than a system sheet — a real `NSWindow` sheet on this floating, non-resizable panel repaints incorrectly while its content resizes across states.

### Sandbox

`ENABLE_APP_SANDBOX = NO` — required because the app shells out directly to `sshpass`, `ssh`, `scp`, and `pymobiledevice3` via `Process`, which the sandbox would block.
