# vbound

> [!NOTE]
> This is a developer companion tool. It requires [vphone-cli](https://github.com/nickcoutsos/vphone), [loader-ios](https://github.com/unbound-app/loader-ios), and the CLI dependencies listed below to be useful.

macOS floating panel that attaches to the vphone window and streamlines Unbound development: boot the virtual device, build and deploy the tweak over SSH, and stream live device logs.

![vbound](https://adriancastro.dev/teh7wd8ywezj.png)

## Requirements

- macOS 26+
- [vphone-cli](https://github.com/nickcoutsos/vphone) — virtual iPhone environment
- [loader-ios](https://github.com/unbound-app/loader-ios) — Unbound tweak source
- [pymobiledevice3](https://github.com/doronz88/pymobiledevice3) — `pip install pymobiledevice3`
- [sshpass](https://formulae.brew.sh/formula/sshpass) — `brew install sshpass`

## Building

1. Clone this repository.
2. Open `vbound.xcodeproj` in Xcode 26+.
3. Select your team under Signing & Capabilities.
4. Build and run (`⌘R`).

## Usage

vbound automatically detects the vphone window and attaches its panel to the right edge. Configure folder paths on the Home tab before first use.

| Action | Description |
| --- | --- |
| **Boot vphone** | Runs `make boot` in the vphone-cli folder |
| **Shut Down** | Gracefully shuts down the virtual device via `pymobiledevice3 diagnostics shutdown` |
| **Launch Discord** | Kills and relaunches Discord on the virtual device |
| **Build & Install Unbound** | Builds the tweak (`gmake package`) and deploys it via SSH on port 2222 |
| **Stream** | Live-tails device logs filtered to `app.unbound` and `com.facebook.react` subsystems |

Port forwarding (SSH on 2222) is handled automatically by `pymobiledevice3 usbmux forward` whenever an SSH or build action is triggered.

## Contributors

[![Contributors](https://contrib.rocks/image?repo=unbound-app/vbound)](https://github.com/unbound-app/vbound/graphs/contributors)
