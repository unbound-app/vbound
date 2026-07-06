# Changelog

All notable changes to vbound are documented here. Format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/); this project uses
[Semantic Versioning](https://semver.org/).

Releases before 0.8.0 are documented in their
[GitHub Releases](https://github.com/unbound-app/vbound/releases) entries only.

## [Unreleased]

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
