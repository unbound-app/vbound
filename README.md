# vbound

> [!NOTE]
> This is a developer companion tool. It requires [vphone-cli](https://github.com/nickcoutsos/vphone), [loader-ios](https://github.com/unbound-app/loader-ios), and the CLI dependencies listed below to be useful.

macOS-native workspace that attaches to the vphone window and streamlines Unbound development: boot the virtual device, deploy the tweak and addons over SSH, stream live device logs, and work in an integrated shell.

![vbound](https://adriancastro.dev/96557kk9tr3z.png)

## Requirements

- macOS 26+
- [vphone-cli](https://github.com/nickcoutsos/vphone) — virtual iPhone environment
- [loader-ios](https://github.com/unbound-app/loader-ios) — Unbound tweak source
- [pymobiledevice3](https://github.com/doronz88/pymobiledevice3) — `pipx install pymobiledevice3`
- [sshpass](https://formulae.brew.sh/formula/sshpass) — `brew install sshpass`
- Optional, for mounting vphone in Finder: [macFUSE](https://macfuse.github.io) + sshfs —
  `brew install --cask macfuse && brew install gromgit/fuse/sshfs-mac`.
  After installing, **macOS will block the macFUSE kernel extension** — go to
  System Settings → Privacy & Security, click Allow next to the blocked extension, and
  restart if prompted. Not FUSE-T: it has an open, unfixed upstream bug
  ([macos-fuse-t/fuse-t#63](https://github.com/macos-fuse-t/fuse-t/issues/63)) where it
  doesn't honor the FUSE readdir offset contract, breaking directory listings outright.
  vbound specifically looks for sshfs at `/opt/homebrew/bin/sshfs`, where the
  macFUSE-targeted build installs. The mount authenticates as `mobile`, but vbound
  automatically grants that account passwordless `sudo` for just the device's
  `sftp-server` binary and routes the mount through it, so root-owned paths
  (`.fseventsd`, `dirs_cleaner`, etc.) are visible too — the same trust boundary the
  Tweak/Addons actions already rely on for `sudo dpkg`/`killall`.

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
| **Mount** | Mounts or unmounts vphone's filesystem at `~/vphone` over SSHFS; use the device menu to reveal an active mount in Finder |

Port forwarding (SSH on 2222) is handled automatically by `pymobiledevice3 usbmux forward` whenever an SSH or build action is triggered.

## Contributors

[![Contributors](https://contrib.rocks/image?repo=unbound-app/vbound)](https://github.com/unbound-app/vbound/graphs/contributors)
