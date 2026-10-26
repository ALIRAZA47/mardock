# Security

MarDock replaces one of the most-used parts of macOS, so it is built to be
boring from a security point of view: it can't reach the network, it can't read
your files, it never runs scripts or other programs, and the one component with
more power than the sandbox allows can only do a handful of narrowly defined
things.

This document describes the design, what each guarantee rests on, and how to
check it yourself.

## Architecture

```
┌──────────────────────────────┐   XPC (bounded, validated JSON)   ┌───────────────────────────────┐
│ MarDock.app                  │ ────────────────────────────────▶ │ MarDock Helper (.xpc)          │
│ • the dock, settings, menus  │                                   │ • embedded in MarDock.app      │
│ • App Sandbox                │ ◀──────────────────────────────── │ • Hardened Runtime, no         │
│ • no network entitlement     │        typed replies              │   entitlements                 │
│ • Hardened Runtime           │                                   │ • 7 allowlisted operations     │
└──────────────────────────────┘                                   └───────────────────────────────┘
```

The dock itself — all of the UI, drag and drop, icon decoding, preferences —
runs inside the **App Sandbox**. Its only entitlements are:

| Entitlement | Why |
| --- | --- |
| `com.apple.security.app-sandbox` | Confines the process. |
| `com.apple.security.files.user-selected.read-write` | Lets MarDock open or save the files you pick in an Open or Save panel (apps to add, images for icons, theme and settings files), and nothing else. |

There is no network entitlement, so the sandbox refuses every socket the app
could open. There is no Accessibility, Screen Recording, Input Monitoring,
Automation or Full Disk Access permission, and none is ever requested.

The sandbox correctly forbids two things a dock needs: quitting other apps and
changing the macOS Dock's preferences (to hide or tune it). Those are done by a
small **XPC helper** embedded in the app bundle. (Hiding other apps turned out
to be blocked as well, so the helper does that too.) It is not sandboxed, so it is
designed to be as small and strict as possible.

## The helper

### Who can talk to it

1. **launchd scoping.** An XPC service inside an app bundle can only be looked up
   by the app that contains it.
2. **Code-signing requirement.** On every connection the helper requires the
   peer to satisfy the *designated requirement of the exact app bundle it lives
   in*, computed at start-up from that bundle's signature:
   - Developer ID builds: same bundle identifier and same Team ID.
   - Local ad-hoc builds: the app's exact code hash.
3. **Fail closed.** If the containing app's signature doesn't validate (all
   architectures, nested code, strict mode), the helper refuses every connection.

The app, in turn, requires the helper to carry the expected identifier (and,
for Developer ID builds, the same Team ID) before talking to it.

### What it can do

Everything the helper understands is the `AgentRequest` enum in
[`Sources/MarDockCore/AgentMessages.swift`](Sources/MarDockCore/AgentMessages.swift).
Messages are JSON, capped at 64 KB, decoded strictly and validated before
anything happens:

| Operation | Validation |
| --- | --- |
| Read macOS Dock settings | Only the 15 keys in `SystemDockSchema`; values type-checked. |
| Change macOS Dock settings | Each key must be in `SystemDockSchema`, with the right type and within range (e.g. `tilesize` 16–128, `mineffect` ∈ genie/scale/suck). No duplicates. Rate limited. The Dock is restarted with `SIGTERM`, at most every 1.5 s. |
| List apps in the macOS Dock | Parsed defensively from `persistent-apps`: bundle IDs and paths validated, list capped, nonexistent apps dropped. |
| Quit an app | The pid must still belong to the claimed bundle ID (pids get reused), it must be a regular foreground app, and never Finder, the Dock, login window, other system UI, MarDock itself or the requesting process. Rate limited. |
| Hide or show an app | Same pid/bundle-ID/regular-app checks (hiding Finder is allowed, as in the macOS Dock). Rate limited. |
| Open the Trash | No parameters. |
| Verify integrity | Re-validates both signatures and reports the result. |

There is no operation that takes a path to open, a command to run, a script to
evaluate, or an arbitrary preference key to write.

## Guarantees and how they are enforced

| Guarantee | Enforced by | Checked by |
| --- | --- | --- |
| No network access | No network entitlement → sandbox denies sockets | Self-test tries to connect and expects `EPERM`; audit fails if either binary imports socket, `URLSession`, Network.framework or similar APIs |
| No running other code | No `Process`/`NSTask`, `system`, `popen`, `posix_spawn`, `NSAppleScript`, `dlopen` anywhere | Audit scans imported symbols of both binaries (all architectures) |
| No code injection | Hardened Runtime on both executables, no exception entitlements (library validation stays on) | Audit checks the `runtime` flag and the exact entitlement sets |
| Least privilege | Sandbox + 1 file entitlement; helper allowlist | Audit (entitlements), self-test (helper refuses unknown keys, out-of-range values, garbage, protected apps, pid mismatches) |
| Tamper evidence | Signed bundle; helper validates the app and fails closed | Settings ▸ Privacy & Security ▸ Verify App Integrity |
| Robust parsing | Every external input is bounded and validated: settings, pinned apps, XPC messages, the Dock's plist, dragged files | Unit tests with hostile inputs |
| Reversible changes | Original macOS Dock values are saved before hiding and restored on quit | Self-test, manual recovery below |
| Small supply chain | No third-party dependencies; plain SwiftPM, readable build script | `Package.swift` has no dependencies |

## Verify it yourself

```sh
make audit      # entitlements, Hardened Runtime, signatures, imported APIs, bundle contents
make selftest   # runs the sandbox/helper/network checks against your real system
swift test      # engine, validation and protocol tests
```

In the app: **Settings ▸ Privacy & Security** shows the live sandbox,
entitlement and signature status, and **Verify App Integrity** re-checks both
signatures.

CI runs the unit tests, the audit and the end-to-end self-test on every push.

## Restoring the macOS Dock manually

MarDock restores the macOS Dock when it quits. If it ever can't (for example
after a crash), either reopen MarDock and choose **Restore the macOS Dock** in
its menu bar menu, or run:

```sh
defaults delete com.apple.dock autohide-delay
defaults write com.apple.dock autohide -bool false
killall Dock
```

## Distribution notes

- Local builds are signed ad-hoc. To distribute, build with a Developer ID
  (`SIGN_IDENTITY="Developer ID Application: …" make app`) and notarize
  (see README).
- GitHub Actions in this repo run with read-only permissions and no secrets.
  For extra supply-chain hardening, pin the actions to commit SHAs.

## Reporting a vulnerability

Please report security issues privately through GitHub's
**Security ▸ Report a vulnerability** on this repository rather than in a
public issue.
