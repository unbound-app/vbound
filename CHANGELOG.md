# Changelog

All notable changes to vbound are documented here. Format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/); this project uses
[Semantic Versioning](https://semver.org/).

Releases before 0.8.0 are documented in their
[GitHub Releases](https://github.com/unbound-app/vbound/releases) entries only.

## [Unreleased]

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
