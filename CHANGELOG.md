# Changelog

Notable changes to MarDock, newest first. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and versions follow
[Semantic Versioning](https://semver.org/spec/v2.0.0.html). Each release's
downloads, checksums and build provenance are on the
[Releases](https://github.com/ALIRAZA47/mardock/releases) page.

## [Unreleased]

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

[Unreleased]: https://github.com/ALIRAZA47/mardock/compare/v1.0.0...HEAD
[1.0.0]: https://github.com/ALIRAZA47/mardock/releases/tag/v1.0.0
