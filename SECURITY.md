# Security

MarDock replaces one of the most-used parts of macOS, so it is built to be
boring from a security point of view: the dock can't reach the network, it
can't read your files, it never runs scripts or other programs, the one
component with more power than the sandbox allows can only do a handful of
narrowly defined things, and the one component that may use the network is
sandboxed and can only fetch this repository's releases, when you ask.

This document describes the design, what each guarantee rests on, and how to
check it yourself.

## Architecture

```
┌──────────────────────────────┐   XPC (bounded, validated JSON)   ┌───────────────────────────────┐
│ MarDock.app                  │ ────────────────────────────────▶ │ MarDock Helper (.xpc)          │
│ • the dock, settings, menus  │                                   │ • embedded in MarDock.app      │
│ • App Sandbox                │ ◀──────────────────────────────── │ • Hardened Runtime, no         │
│ • no network entitlement     │        typed replies              │   entitlements                 │
│ • Hardened Runtime           │                                   │ • 13 allowlisted operations    │
└──────────────────────────────┘                                   └───────────────────────────────┘
               │  XPC: "latest release?" / "download version x"
               ▼
┌──────────────────────────────┐
│ MarDock Updater (.xpc)       │   HTTPS, GET only, to this repository's releases on GitHub
│ • embedded in MarDock.app    │ ─────────────────────────────────────────────────────────▶
│ • App Sandbox + outgoing     │
│   network, nothing else      │
│ • Hardened Runtime           │
└──────────────────────────────┘
```

The dock itself — all of the UI, drag and drop, icon decoding, preferences —
runs inside the **App Sandbox**. Its only entitlements are:

| Entitlement | Why |
| --- | --- |
| `com.apple.security.app-sandbox` | Confines the process. |
| `com.apple.security.files.user-selected.read-write` | Lets MarDock open or save the files you pick in an Open or Save panel (apps to add, images for icons, theme and settings files), and nothing else. |
| `com.apple.security.files.bookmarks.app-scope` | Lets MarDock remember a folder you chose to keep in the dock (a read-only security-scoped bookmark), so it can list that folder's newest files after a restart. |
| `com.apple.security.automation.apple-events` | Lets the app send Apple Events at all (the Hardened Runtime blocks them otherwise)… |
| `com.apple.security.scripting-targets` | …and limits them to Finder's `com.apple.finder.trash` group: **Empty Trash** is the only command the sandbox lets MarDock send, to Finder only. macOS also asks you before the first one. |

There is no network entitlement, so the sandbox refuses every socket the app
could open. MarDock asks for no Accessibility or Screen Recording permission
unless you turn on one of the extras below, Automation for Finder only when you
first choose Empty Trash, and never for Input Monitoring or Full Disk Access.

**Empty Trash** works like the macOS Dock's: MarDock asks Finder to empty the
Trash, after the same question Finder asks (hold ⌥ to skip it), and Finder
does the work. Nothing in the Trash is read or deleted by MarDock itself.

**Shortcuts actions** (switch profile, set the theme, position, hiding or
magnification, open Settings) and the **Focus filter** run inside the same
sandboxed app. Each takes a profile or theme MarDock already has, or one of a
fixed set of options, and changes nothing but MarDock's own dock. The
bundle's `Metadata.appintents` folder is the description of those actions
that Shortcuts reads: data, not code.

### Opt-in extras

Each is off until you turn it on in Settings ▸ Behaviour ▸ Extras, and the
dock works the same without them.

| Extra | Permission | What it reads or does |
| --- | --- | --- |
| Full Trash icon | none | The helper reads the number of entries in `~/.Trash` (a directory attribute): nothing in the Trash is opened or listed. |
| Notification badges | Accessibility | The helper reads the badge text the macOS Dock shows on each app (`AXStatusLabel`), and that app's identifier. |
| Minimized windows | Accessibility | The helper lists regular apps' minimized windows (title only) and, when you click one, unminimizes and raises it. The pid must belong to the claimed app, never Finder, other system UI or MarDock itself. |
| Window previews | Screen Recording | The sandboxed app takes small pictures of the windows of the app you point at (ScreenCaptureKit), shows them, and keeps nothing. |

The Accessibility work runs in the helper, which isn't sandboxed. macOS
records that permission for MarDock.app as a whole (the helper is part of
that bundle), which is what you allow in System Settings; the sandboxed app
never calls an Accessibility API itself, and the audit fails if its binary
ever imports one. The helper's requests are refused while the permission is
missing, and it never reads window contents, text fields or anything outside
the list above. Importing a settings file never turns an extra on or off:
those choices stay as they are on this Mac.

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
| Change macOS Dock settings | Each key must be in `SystemDockSchema`, with the right type and within range (e.g. `tilesize` 16–128, `mineffect` ∈ genie/scale/suck). No duplicates. Rate limited. The Dock — only the process running from `/System/Library/CoreServices/Dock.app`, whatever else claims its identifier — is restarted with `SIGTERM`, at most every 1.5 s. |
| List apps in the macOS Dock | Parsed defensively from `persistent-apps`: bundle IDs and paths validated, list capped, nonexistent apps dropped. |
| Quit an app | The pid must still belong to the claimed bundle ID (pids get reused), it must be a regular foreground app, and never Finder, the Dock, login window, other system UI, MarDock itself or the requesting process. Rate limited. |
| Hide or show an app | Same pid/bundle-ID/regular-app checks (hiding Finder is allowed, as in the macOS Dock). Rate limited. |
| Open the Trash | No parameters. |
| Verify integrity | Re-validates both signatures and reports the result. |
| Is the Trash full | No parameters; reads the entry count of `~/.Trash` only. Rate limited. |
| Accessibility status | Says whether MarDock may use Accessibility; can show macOS's request (rate limited). |
| Read Dock badges | Needs Accessibility. Reads only the badge text and app of the items of the real macOS Dock (the process running from `/System/Library/CoreServices/Dock.app`); labels capped at 8 characters, 64 badges. Rate limited. |
| List minimized windows | Needs Accessibility. Regular apps only, never the parts of macOS that can't be quit (Finder included) and never MarDock; titles cleaned and capped at 80 characters, 32 windows. Rate limited. |
| Install an update | Only through its own XPC entry point, with the downloaded archive passed as an open file. The version must be well formed and newer than the installed copy; the archive is copied into a file only the helper writes, and the copy must match the SHA-256 the release published; every entry must be a plain file or folder inside `MarDock.app/` (no links, no `..`); the extracted app must have the same bundle identifier and exactly that version, and be validly signed (strict, all architectures, nested code) with the Hardened Runtime — and, when the installed copy is signed with a Developer ID, satisfy its designated requirement (same team). Only the app the helper is embedded in is replaced, never a path from the request, and not from a read-only volume or App Translocation. Rate limited. |
| Bring back a window | Needs Accessibility. Same pid/bundle-ID/regular-app checks as quitting, so never Finder, other system UI or MarDock. Unminimizes, raises and brings forward that one window. Rate limited. |

There is no operation that takes a path to open, a command to run, a script to
evaluate, or an arbitrary preference key to write.

## The updater

Update checks are the one thing that needs the network, so they live in their
own XPC service rather than in the dock:

- **Sandboxed**, with outgoing network connections as its only other
  entitlement. It can't read your files or the dock's data.
- **Only GitHub, only this repository.** Every URL is built from constants
  (`UpdateSource` in [`Updates.swift`](Sources/MarDockCore/Updates.swift)) and a
  version that must look like `1.2.3`: the latest-release description from
  GitHub's API, and a release's `SHA256SUMS.txt` and `MarDock-<version>.aar`.
  HTTPS only; redirects are followed only to GitHub's own hosts; replies are
  size-capped. No cookies, cache, credentials or identifying headers.
- **Only when you ask.** Check for Updates (menu bar menu, Settings ▸ About),
  or once a day if you turn that on. It's off by default, and importing a
  settings file can't turn it on.
- **Can't install anything.** It downloads the archive into its own container,
  checks it against the release's checksum, and hands it to the app as an
  open file. The helper then checks it again (see *Install an update* above)
  before replacing MarDock.app, and the app relaunches.
- **Who can talk to it.** launchd lets only the containing app look it up.
  Being sandboxed, it can't read that app to pin its exact signature, so it
  requires the app's identifier and, for Developer ID builds, the same team.

For ad-hoc builds there's no developer signature to compare, so what vouches
for an update is the checksum published with the release on GitHub — the same
trust as downloading it by hand. Developer ID builds also require the update
to be signed by the same team.

## Guarantees and how they are enforced

| Guarantee | Enforced by | Checked by |
| --- | --- | --- |
| An offline dock | App: no network entitlement → the sandbox denies sockets. Helper: it isn't sandboxed, so this rests on its small source having no networking code, which the audit checks. Updater: sandboxed, network to GitHub's release hosts only by construction | Self-test tries to connect from the app and expects `EPERM`; audit fails if the app or helper imports socket, `URLSession`, Network.framework or similar APIs, or if any sources but the updater's mention them, and checks each executable's exact entitlements |
| Updates are genuine | Release checksum checked by the updater and again by the helper; archive contents, identity, version and signature checked before anything is replaced | Unit tests (versions, checksums, archive paths, release parsing); self-test (helper refuses junk archives and installs without one) |
| No running other code | No `Process`/`NSTask`, `system`, `popen`, `posix_spawn`, `NSAppleScript`, `dlopen` anywhere, and nothing looked up by name (`dlsym`, `NSClassFromString`, selectors from strings) that could hide one. The only Apple Event is Finder's Empty Trash, limited by the sandbox | Audit scans imported symbols of all three binaries (all architectures), the sources for lookups by name, and the app's scripting targets |
| No code injection | Hardened Runtime on all three executables, no exception entitlements (library validation stays on) | Audit checks the `runtime` flag and the exact entitlement sets |
| Least privilege | Sandbox + access only to files and folders you pick; helper allowlist; Accessibility and Screen Recording only for extras you turn on, and only the helper calls Accessibility | Audit (entitlements, no Accessibility API in the app binary), self-test (helper refuses unknown keys, out-of-range values, garbage, protected apps, pid mismatches, and window requests without Accessibility) |
| Tamper evidence | Signed bundle; helper validates the app and fails closed | Settings ▸ Privacy & Security ▸ Verify App Integrity |
| Robust parsing | Every external input is bounded and validated: settings, pinned apps, XPC messages, the Dock's plist, dragged files | Unit tests with hostile inputs |
| Reversible changes | Original macOS Dock values are saved before hiding and restored on quit | Self-test, manual recovery below |
| Small supply chain | No third-party dependencies; plain SwiftPM, readable build script | `Package.swift` has no dependencies |

## Verify it yourself

```sh
make audit      # entitlements, Hardened Runtime, signatures, imported APIs, bundle contents
make selftest   # runs the sandbox/helper/network/update checks against your real system
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
- Releases come from the **Release** workflow, which runs only for version
  tags (or by hand). It is the only workflow that sees the signing and
  notary secrets and the only one that can write (to create the release).
  It runs the security audit on the exact app it ships, signs it with
  the Developer ID kept in a throwaway keychain (deleted as soon as the
  disk image is signed, before notarization, attestation and publishing),
  notarizes the app and the disk image, and publishes SHA-256 checksums
  and a build provenance attestation (`gh attestation verify`) next to them.
  The `.aar` it publishes is the same app, packed with `aa archive`, for
  MarDock's updater.
- The CI workflow runs with read-only permissions and no secrets, and packs
  the **MarDock-app** artifact straight after the audit, before the
  self-test, screenshot and tour steps run anything else on the runner.
- Both workflows pin the actions they use to commit SHAs. Anyone who can
  push to the repository can push a `v*` tag, so a tag protection rule
  for `v*` is the way to limit who can cut a release.

## Reporting a vulnerability

Please report security issues privately through GitHub's
**Security ▸ Report a vulnerability** on this repository rather than in a
public issue.
