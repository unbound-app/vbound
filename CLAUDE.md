# vbound

macOS SwiftUI floating panel for Unbound (Discord tweak) development on vphone.

## Architecture

Single fixed-size window (520×340, non-resizable, floating level) that:
- Detects the vphone window via `CGWindowList` and snaps to its right edge, polling every 100ms
- Drives `vphone-cli`, `sshpass`/SSH, and `pymobiledevice3` through `Process` subprocesses
- Streams device logs via `pymobiledevice3 syslog live --udid <id>` (persistent process, no polling), filtered in-process to `app.unbound` and `facebook.react` subsystems
- SSH target: `mobile@127.0.0.1:2222`, port-forwarded by `pymobiledevice3`; default password `alpine`

## Key files

- `vbound/ContentView.swift` — all SwiftUI: Home tab (actions + folder config) and Logs tab (filter bar, log rows)
- `vbound/AppController.swift` + `AppController+*.swift` — `@Observable` backing model split into extensions: window attachment, build pipeline, log streaming, device actions, process helpers
- `vbound/vboundApp.swift` — app entry point

## Build

Open `vbound.xcodeproj` in Xcode 26+, select a signing team, and run (⌘R). No external build tools required.

## Conventions

- All async work lives in `AppController` extensions using `Task`/`async await`
- Log streaming: persistent `pymobiledevice3 syslog live` process read via `readabilityHandler`; device discovered via `pymobiledevice3 usbmux list` JSON (`Identifier` + `ProductType` fields)
- `enrichedEnvironment` adds Homebrew paths so CLI tools are found without a login shell
- Build progress is estimated by counting `.x`/`.xm`/`.m`/`.mm` source files
