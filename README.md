# vbound

> [!NOTE]
> This is a developer companion tool. It requires [vphone-cli](https://github.com/nickcoutsos/vphone), [loader-ios](https://github.com/unbound-app/loader-ios), and the CLI dependencies listed below to be useful.

macOS floating panel that attaches to the vphone window and streamlines Unbound development: boot the virtual device, deploy the tweak and plugins over SSH, and stream live device logs.

![vbound](https://adriancastro.dev/96557kk9tr3z.png)

## Requirements

- macOS 26+
- [vphone-cli](https://github.com/nickcoutsos/vphone) — virtual iPhone environment
- [loader-ios](https://github.com/unbound-app/loader-ios) — Unbound tweak source
- [pymobiledevice3](https://github.com/doronz88/pymobiledevice3) — `pipx install pymobiledevice3`
- [sshpass](https://formulae.brew.sh/formula/sshpass) — `brew install sshpass`
- Optional, for mounting vphone in Finder: [FUSE-T](https://www.fuse-t.org) + FUSE-T's own sshfs build —
  `brew install --cask fuse-t && brew tap macos-fuse-t/homebrew-cask && brew install --cask macos-fuse-t/homebrew-cask/fuse-t-sshfs`
  (`brew trust macos-fuse-t/homebrew-cask` first if Homebrew refuses the tap).
  Use this exact package, not the more commonly recommended `gromgit/fuse/sshfs-mac` —
  that one is built against classic macFUSE/libfuse headers and silently fails to
  actually attach the mount under FUSE-T (exits successfully, prints "library too old",
  and the mount point just stays empty). vbound specifically looks for sshfs at
  `/usr/local/bin/sshfs`, where the FUSE-T build installs.

## Building

1. Clone this repository.
2. Open `vbound.xcodeproj` in Xcode 26+.
3. Select your team under Signing & Capabilities.
4. Build and run (`⌘R`).

## Usage

vbound automatically detects the vphone window and attaches its panel to the right edge. Configure folder paths, the device password, and automation options from **Settings** (⌘,) before first use.

| Action | Description |
| --- | --- |
| **Boot vphone** | Runs `make boot` in the vphone-cli folder |
| **Shut Down** | Gracefully shuts down the virtual device via `pymobiledevice3 diagnostics shutdown` |
| **Discord** | Kills and relaunches Discord on the virtual device |
| **Tweak** | Builds the tweak (`gmake package`) and deploys it via SSH on port 2222 |
| **Addons** | Builds every plugin (`bunx ubd build`), replaces each deployed plugin with its `dist/` contents, then relaunches Discord |
| **Stream** | Live-tails device logs filtered to `app.unbound` and `com.facebook.react.log` subsystems, with an optional merged view |
| **Shell** | Opens an SSH terminal session to the device (`mobile@127.0.0.1:2222`) |
| **Mount (folder icon)** | Mounts vphone's filesystem at `~/vphone` over SSHFS; click again to open it in Finder, right-click to unmount |

Port forwarding (SSH on 2222) is handled automatically by `pymobiledevice3 usbmux forward` whenever an SSH or build action is triggered.

## Contributors

[![Contributors](https://contrib.rocks/image?repo=unbound-app/vbound)](https://github.com/unbound-app/vbound/graphs/contributors)
