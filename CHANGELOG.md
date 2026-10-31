# Changelog

Notable changes to MarDock, newest first. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and versions follow
[Semantic Versioning](https://semver.org/spec/v2.0.0.html). Each release's
downloads, checksums and build provenance are on the
[Releases](https://github.com/ALIRAZA47/mardock/releases) page.

## [Unreleased]

### Added

- **Double-click shortcuts.** Double-click an app in the dock for a small
  panel with its own New and Open commands and their keyboard shortcuts, your
  own websites, files and Shortcuts for that app, and Hide, Hide Others, Show
  in Finder and Quit. Right-click an app for the same panel, or set a
  double-click to hide the app, hide the others or do nothing in Settings ▸
  Shortcuts. Reading an app's commands needs Accessibility; everything else
  on the panel doesn't.
- **Open at Login** in the menu bar menu, and an Edit menu while Settings is
  in front, so text fields can cut, copy and paste.

### Changed

- **Settings is redesigned.** A sidebar with search finds any setting and
  points it out. General comes first, with Open at login and Replace the
  macOS Dock at the top. Shortcuts and Extras have pages of their own, the
  Appearance preview stays in view while you change things below it, and
  your own themes sit in the same grid as the built-in ones.
- Export Settings now includes your shortcuts.

### Fixed

- **About no longer looks empty.** The page stretched the Settings window to
  thousands of points tall, which left its content far out of view. No page
  can resize the window now.
- **The macOS Dock stays hidden.** It used to come up whenever an app bounced
  for attention, and could move to whichever display the pointer pushed
  against; MarDock now turns off both, and puts them back as they were when it
  restores the Dock.
- **The macOS Dock hides again after quitting and reopening MarDock**, even if
  the welcome screen was never finished. Choices made in Settings now hold
  from launch.
- **Get Started is always on the welcome screen.** Its window was too short
  for its content and couldn't be resized, so the button was cut in half, or
  on macOS 27 out of sight altogether. The button now stays outside the part
  that scrolls, and the window is tall enough for everything.
- **Open at login** was only ever set up by Get Started, and its switch was at
  the bottom of a long page. Closing the welcome screen now counts as an
  answer, and importing the macOS Dock's apps, which replaces what's in
  MarDock, starts unticked if you've already arranged your dock.
- Changing a macOS Dock setting within a second or so of the last change no
  longer leaves it waiting for the next login: the Dock restart waits its turn
  instead of being dropped.

## [1.1.0] - 2026-10-28

### Added

- **Empty Trash** from the Trash tile's menu. It asks the same question
  Finder does (hold ⌥ to skip it), and MarDock asks Finder to do the
  emptying, as the macOS Dock does: macOS asks once for Automation permission
  for Finder, and the sandbox lets MarDock send Finder that one command and
  no other.
- **Updates when you want them.** Check for Updates… in the menu bar menu,
  the app menu and Settings ▸ About, plus a daily check that is off by
  default. A separate sandboxed updater fetches only this repository's
  releases; the download is checked against the release's checksum and its
  signature before the helper swaps the app, and the new MarDock starts once
  the old one has quit. Releases now include the archive the updater
  installs, so this is the last update that has to be done by hand.
- The project is open source under the MIT License, with a contributing
  guide, a code of conduct, issue and pull request templates, and this
  changelog.

### Fixed

- Importing from a macOS Dock full of apps with long paths brings over as
  many as fit instead of failing.
- The minimized-windows extra never lists or raises windows of Finder, other
  parts of macOS or MarDock itself, matching what Quit allows.
- A helper reply that is too large to send shows an error instead of doing
  nothing.

## [1.0.0] - 2026-10-27

The first release.

- A dock for macOS 14 and later with physically based magnification that keeps
  the icon under your pointer still, spring physics for every motion, launch
  bounces, click ripples, a poof when you drag an app off, a specular highlight
  that follows the pointer and drifting aurora colours.
- Seven themes (Glass, Liquid, Aurora, Midnight, Sunset, Mirror and Minimal),
  a theme editor with a live preview, accent colours and running-indicator
  styles.
- Folder stacks, profiles, spacers and named dividers, a Share tile, a recent
  apps section, custom icons, keyboard launching with ⌃⌥1–9, and Shortcuts,
  Siri and Focus actions.
- Bottom, left or right, on the main display or following the pointer;
  auto-hide never, always or only when a window overlaps; drag and drop to
  add, reorder, remove and open; VoiceOver, Reduce Motion, Reduce Transparency
  and Increase Contrast support.
- Export and import of the dock, settings, themes, profiles and icons.
- Optional extras, off by default: notification badges and minimized windows
  (Accessibility), window previews (Screen Recording) and a full Trash icon.
- Tuning of the macOS Dock itself, and hiding it while MarDock runs, with its
  settings saved first and restored on quit.
- Private by design: App Sandbox, no network entitlement, Hardened Runtime, a
  tiny allowlisted XPC helper, no third-party dependencies, and a security
  audit and self-test that run in CI on every change.

[Unreleased]: https://github.com/ALIRAZA47/mardock/compare/v1.1.0...HEAD
[1.1.0]: https://github.com/ALIRAZA47/mardock/compare/v1.0.0...v1.1.0
[1.0.0]: https://github.com/ALIRAZA47/mardock/releases/tag/v1.0.0
