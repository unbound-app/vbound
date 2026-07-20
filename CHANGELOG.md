# Changelog

All notable changes to vbound are documented here. Format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/); this project uses
[Semantic Versioning](https://semver.org/).

Releases before 0.8.0 are documented in their
[GitHub Releases](https://github.com/unbound-app/vbound/releases) entries only.

## [Unreleased]

## [0.13.2] - 2026-07-20

### Changed

- Addon deployment is back to always using `scp` + SSH, regardless of whether vphone is
  mounted. The mounted copy still moves the same bytes over the same SFTP transport, so
  it wasn't a meaningful speedup — not worth coupling the automated deploy pipeline to
  FUSE's reliability for a marginal (if any) gain. The Finder mount stays as a standalone
  convenience for manually browsing/dragging files.

### Fixed

- Unmounting a genuinely-attached FUSE-T mount didn't reliably respond to plain `umount`
  (confirmed directly: it can report success or "not mounted" while `mount` still lists
  the entry). Unmount now falls back to `diskutil unmount force` when the mount is still
  present afterward.
- The Mount/Finder button showed the window's default keyboard-focus ring whenever
  vbound became the key window, making the folder glyph hard to see.

## [0.13.1] - 2026-07-20

### Fixed

- The Finder-mount feature silently no-opped: `gromgit/fuse/sshfs-mac`, the more
  commonly recommended sshfs package, is built against classic macFUSE/libfuse headers
  and isn't actually compatible with FUSE-T — it exits successfully without ever
  attaching the mount, leaving `~/vphone` empty and making Unmount look like it does
  nothing (there was never anything mounted to unmount). vbound now looks specifically
  for FUSE-T's own sshfs build at `/usr/local/bin/sshfs`
  (`macos-fuse-t/homebrew-cask/fuse-t-sshfs`) and verifies against `mount` output
  rather than trusting sshfs's exit code, so a broken mount can't be reported as
  successful again.
- The `~/vphone` mount point's custom icon is now the standard folder glyph with a
  small phone badge, not a bare phone icon replacing the folder shape.

## [0.13.0] - 2026-07-20

### Added

- vphone can now be mounted in Finder over SSHFS. A folder icon next to the
  status indicator mounts it at `~/vphone` (requires
  [FUSE-T](https://www.fuse-t.org) and `gromgit/fuse/sshfs-mac`, checked
  automatically); click again to open it in Finder, right-click to unmount.
  The mount is torn down automatically on shutdown and app quit.

### Changed

- When vphone is mounted, the Addons action deploys by copying straight into
  Discord's container on the mounted volume instead of `scp`-ing to a staging
  path and moving it into place over SSH.

## [0.12.1] - 2026-07-20

### Fixed

- Starting an addon build turned the Tweak button into the Cancel button
  instead of the Addons button that was actually clicked, since both build
  pipelines shared one running-state flag. The Tweak and Addons buttons now
  each track their own build target, so only the button that started a build
  turns into its Cancel control.

## [0.12.0] - 2026-07-20

### Added

- Plugin deployment: vbound builds every plugin in the configured workspace,
  replaces each plugin's deployed `dist/` payload on vphone, and relaunches
  Discord. The Discord data-container UUID is discovered on-device, so it
  remains correct across installs.
- An Addon Workspace folder picker in Settings.

### Changed

- The status-strip controls are now labelled Discord, Tweak, and Addons.

### Fixed

- Plugin builds now include Bun's standard `~/.bun/bin` location in vbound's
  process environment, allowing the Addons action to find `bunx` when the app
  is launched outside a shell.
- Addon deployment no longer relies on nested remote-shell quoting and skips
  local SSH-key offers before authenticating with the configured device password.

## [0.11.2] - 2026-07-20

### Fixed

- 0.11.1's window-matching fix relied on reading vphone-cli's window
  titles, which macOS silently blanks out unless vbound has Screen
  Recording permission (which it has no reason to ask for) — so
  attachment stopped working entirely instead of just picking the wrong
  window. Matching now uses window shape (the phone display is portrait
  and a minimum plausible size; vphone-cli's "Files"/"Keychain" browser
  windows and its transient preview/QuickLook windows aren't), which
  needs no special permission.

## [0.11.1] - 2026-07-20

### Fixed

- vbound would sometimes attach and snap to vphone-cli's "Files" or
  "Keychain" browser windows instead of the actual phone display window,
  since both are owned by the same process and matching only checked the
  process/title loosely.
- The panel would stay glued on top of the screen at its floating window
  level if vphone was dismissed some way other than quitting or a literal
  Dock miniaturize (e.g. swept away by Stage Manager). It now hides itself
  whenever the phone window disappears, matching vphone's own dismissal.

## [0.11.0] - 2026-07-06

### Added

- Sound cues on build completion (success/failure).
- Copy buttons in the log view's structured-data and timestamp popovers.
- "View on GitHub" and "Report an Issue…" links in the app menu.
- A version number footer in Settings.
- Tab-switch keyboard shortcuts (⌘1/⌘2/⌘3) and Escape-to-clear on the log filter field.
- ⌘K clears the active view's content — logs or shell output, depending on
  which tab is showing — matching Terminal.app's own convention.
- A "Show Password" reveal toggle for the device password field in Settings.
- Busy-state indicators (spinner, disabled controls, "Booting…"/"Connecting…"
  labels) while booting vphone, resolving the log-stream device, or
  mid-handshake connecting the shell.
- Context-aware tooltips on Boot/Build explaining why they're currently
  disabled instead of a static label regardless of state.

### Changed

- The status strip's Boot/Stop are now a single toggling button instead of
  two permanently-visible ones, matching the existing Stream/Connect pattern;
  freed-up space went to a larger control size and a text label on Settings.
- Renamed several controls for clarity: "Discord" → "Launch Discord",
  "Build" → "Build Tweak", "Cancel" → "Cancel Build". The Actions menu and
  status strip stay in sync with each other, including Boot/Shut Down now
  being one toggling menu item there too.
- The shell's ^L control key now actually clears the local scrollback
  instead of only forwarding the byte to the remote and leaving the existing
  history in place.
- ⌘Q and Dock → Quit now show the same "build in progress" / "vphone booted
  by vbound" confirmation warnings the window's close button already had —
  previously only the close button routed through them.
- File → New Window is disabled; vbound is a single-window utility bound to
  one AppController instance, and a second window would have silently
  broken window-attachment for the first.

### Fixed

- Quitting mid-build could leave the build's child process running in the
  background — its process reference wasn't captured/terminated on any
  quit path, the same class of bug already fixed for the shell/log/forward
  processes.
- Toggling the ERR filter off while viewing a tab could hide a real
  incoming error with no indication anywhere — the unread-badge tracking
  assumed "viewing the tab" meant "saw everything in it," regardless of
  the level filter.
- The build pipeline could report "Build installed" even when the final
  Discord-restart step actually failed, since its result was silently
  discarded.
- A pasted device password with trailing whitespace or a newline would
  silently fail SSH/sudo authentication.
- Booting vphone or launching Discord had no guard against being triggered
  again while already in progress, risking multiple concurrent `make boot`
  processes or overlapping SSH restart commands from a few impatient clicks.
- Estimating build steps walked the entire source tree synchronously on the
  main thread, which could visibly hitch the window right as a build starts;
  it now runs off the main thread.
- The log view rebuilt its entire attributed string on every unrelated
  re-render (typing in the shell input, navigating search matches, etc.),
  not just when the log content actually changed.
- The GitHub Actions release workflow was missing the `actions: write`
  permission its DerivedData cache-cleanup step needs.

## [0.10.0] - 2026-07-05

### Added

- A Cancel action for in-progress builds: the status strip's Build button
  turns into a red Cancel button while building/uploading/installing, and
  terminates the active subprocess instead of leaving you to wait it out.
  The Actions menu's "Build & Install" (⌘I) mirrors the same toggle.
- Connect/Disconnect Shell now has an Actions menu entry (⌘T), matching
  every other primary action.
- Find-next/previous navigation for the log filter: matches are counted
  ("N/M" next to the filter field), and ⌘G/⇧⌘G (or the new chevron buttons)
  step between them, with the current match highlighted separately from
  the rest.
- The shell control-key row gained Esc, ↑, and ↓ alongside the existing
  ^C/^D/^Z/^L/Tab.
- Pasting multi-line text into the shell input now sends each complete
  line immediately and leaves a trailing partial line to edit, instead of
  mangling the embedded newlines.

### Changed

- "Skip This Version" in the update sheet is now recoverable: Settings'
  "Reset to Defaults" clears it, and the Advanced tab shows a "Clear"
  button whenever a version is currently skipped.

### Fixed

- The shell toolbar's connection label (`mobile@127.0.0.1:2222` /
  `not connected`) could get clipped now that the control-key row is
  wider — replaced with a fixed "SSH" label; the full address is still
  available as a tooltip.

## [0.9.0] - 2026-07-04

### Added

- A persistent auto-scroll toggle (pin icon) in the log toolbar, replacing
  the old one-shot "scroll to newest" button. It disengages the moment you
  scroll or click into the log view, and re-engages when you scroll back to
  the bottom, switch tabs, or start a stream/build/Discord launch.
- Consecutive identical log lines are now collapsed into a single row with a
  "×N" counter instead of flooding the view with repeats.

### Changed

- New log lines now scroll into view with a smooth animated glide instead of
  snapping down instantly.

### Fixed

- Closing the window (or quitting via ⌘Q/the Dock) could leave orphaned
  child processes — spawned by `sshpass`/`pymobiledevice3`, which don't
  receive the parent's SIGTERM — running in the background. Child-process
  cleanup ran after those process references had already been cleared,
  making it a no-op; it now captures them first.
- A spurious AppKit layout notification (fired on initial view layout, or
  when TextKit settles scroll position a moment after an auto-scroll) could
  silently disengage auto-scroll before any real user interaction happened.

## [0.8.0] - 2026-07-04

### Added

- Right-click "Copy UDID" on the status text once a device is attached.
- `.gitignore` for the project (Xcode user data, build output, SPM artifacts).

### Changed

- The update sheet's changelog now renders real Markdown (bold, bullet lists,
  links) via the Textual package instead of showing raw, unformatted markup.
- Dependabot now groups each ecosystem's updates into a single PR instead of
  one PR per package.
- CI build numbers (`CURRENT_PROJECT_VERSION`) are now derived automatically
  from commit count at release time, decoupled from the manually-chosen
  `MARKETING_VERSION`.
- CI concurrency control moved to job level, so a fast-following push can no
  longer cancel an in-flight release mid-notarization.
- The release job now only runs after the compile-check job succeeds, so a
  version-bumped commit that doesn't build can no longer trigger a release.
- Version-bump detection in CI now only matches semver-shaped git tags.
- The window's zoom button is disabled, since the window is fixed-size and
  zooming can't do anything.
- The window's position is now remembered across relaunches when auto-attach
  is turned off.
- Set a proper copyright string, so the About panel shows one.

### Fixed

- `shutdownVphone()` now also terminates the port-forward process, so a stale
  tunnel can't mask a dead connection on the next reconnect attempt.
- Removed previously-committed, machine-specific Xcode user data
  (breakpoints, workspace/scheme state) from version control.
