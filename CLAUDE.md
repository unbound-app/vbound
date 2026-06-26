# vbound

macOS SwiftUI floating panel for Unbound (Discord tweak) development on vphone.

## Architecture

Single fixed-size window (520×340, non-resizable, floating level) that:
- Detects the vphone window via `CGWindowList` and snaps to its right edge, polling every 100ms
- Drives `vphone-cli`, `sshpass`/SSH, and `pymobiledevice3` through `Process` subprocesses
- Streams device logs via `idevicesyslog archive` + `/usr/bin/log show --style ndjson`, filtered to `app.unbound` and `com.facebook.react.log` subsystems
- SSH target: `mobile@127.0.0.1:2222`, port-forwarded by `pymobiledevice3`; default password `alpine`

## Key files

- `vbound/ContentView.swift` — all SwiftUI: Home tab (actions + folder config) and Logs tab (filter bar, log rows)
- `vbound/WindowAttachmentManager.swift` — `@Observable` backing model: window attachment, build pipeline, log streaming
- `vbound/vboundApp.swift` — app entry point

## Build

Open `vbound.xcodeproj` in Xcode 15+, select a signing team, and run (⌘R). No external build tools required.

## Conventions

- All async work lives in `WindowAttachmentManager` using `Task`/`async await`
- Log streaming: 2-second poll loop (`idevicesyslog archive` → `tar` → `log show ndjson`)
- `enrichedEnvironment` adds Homebrew paths so CLI tools are found without a login shell
- Build progress is estimated by counting `.x`/`.xm`/`.m`/`.mm` source files
