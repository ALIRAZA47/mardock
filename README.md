<p align="center">
  <img src="docs/icon.png" width="160" alt="MarDock icon">
</p>

<h1 align="center">MarDock</h1>

<p align="center">
  A dock for macOS that's fluid, beautiful — and private by design.
</p>

<p align="center">
  <img src="docs/screenshots/dock-glass.jpg" width="820" alt="MarDock's Glass theme, magnifying the Photos icon">
</p>

MarDock replaces (or sits alongside) the macOS Dock with a dock that moves like
it's made of something real: physically based magnification, launch bounces,
ripples, a puff of smoke when you drag an app away, and seven themes from
frosted glass to aurora and neon. It runs in the App Sandbox with no network
access and asks for no special permissions.

## Highlights

**Motion**
- **Magnification that stays under your pointer.** Instead of scaling icons and
  re-centring the row (which makes the icon you're aiming at slide away), MarDock
  warps the dock's axis around the pointer, so whatever is under it stays under it.
- **Real spring physics** for everything — magnification, icons arriving and
  leaving, presses, auto-hide — solved in closed form so it's smooth at any
  refresh rate, including 120 Hz ProMotion.
- **Launch bounces** with a touch of squash and stretch, **click ripples**, a
  **poof** when you drag an app off, a **specular highlight** that follows your
  pointer across the glass, and drifting **aurora** colours.
- **Practically no CPU when idle.** Animation runs off the display's refresh
  only while something moves; ambient effects run in the system's render
  server.

**Looks**
- Seven themes: **Glass**, **Liquid** (real Liquid Glass on macOS 26),
  **Aurora**, **Midnight**, **Sunset**, **Mirror** (glossy floor with
  reflections) and **Minimal**.
- Accent colours, running-indicator styles (glow, dots, lines), optional
  reflections, adjustable icon size, magnification and reach.

**Behaviour**
- Bottom, left or right; main display or follow the pointer between displays.
- Auto-hide: never, always, or **only when a window overlaps the dock**.
- Drag apps from Finder to add them, drag icons to reorder, drag off to remove,
  drop documents on an app to open them with it.
- Right-click an app for Show/Hide/Quit/Force Quit (hold ⌥), Keep in Dock,
  Show in Finder. Right-click the dock for themes, position and hiding.
  ⌘-click reveals an app in Finder; ⌥-click hides it.
- Optionally hides the macOS Dock while MarDock runs, saving your settings first
  and restoring them when MarDock quits.
- Also tunes the **macOS Dock** itself: minimize effect, auto-hide delay and
  animation speed, recent apps, translucent hidden apps and more.

**Accessibility**
- VoiceOver can explore and press every dock item.
- Respects Reduce Motion (no bounces or particles), Reduce Transparency and
  Increase Contrast.

## Themes

<p align="center">
  <img src="docs/screenshots/themes.jpg" width="900" alt="The seven themes: Glass, Liquid, Aurora, Midnight, Sunset, Mirror and Minimal">
</p>

<table>
  <tr>
    <td><img src="docs/screenshots/settings.png" alt="Settings with a live dock preview and theme gallery"></td>
    <td><img src="docs/screenshots/welcome.png" alt="The welcome screen"></td>
  </tr>
  <tr>
    <td align="center">Settings, with a live preview you can play with</td>
    <td align="center">First-run welcome</td>
  </tr>
</table>

<sub>Screenshots are taken automatically by CI on a macOS 15 runner (over a test
backdrop). On macOS 26 the Liquid theme uses the system's real Liquid Glass.</sub>

## Security and privacy

| | |
| --- | --- |
| 🔒 **App Sandbox** | The dock runs sandboxed: it can't read your files or other apps' data. |
| 🌐 **No network** | No network entitlement, so macOS blocks every connection. No analytics, ever. |
| 🛡 **Hardened Runtime** | On every executable, with no exceptions: no code injection, no unsigned libraries. |
| 🧩 **Tiny, locked-down helper** | Quitting or hiding apps and changing the macOS Dock need more than the sandbox allows, so a small XPC helper does exactly that — a handful of allowlisted operations, strictly validated, and it only accepts connections from the exact app it ships in. |
| 🙅 **No special permissions** | No Accessibility, Screen Recording, Input Monitoring, Automation or Full Disk Access. |
| 📦 **No dependencies** | Pure Swift, AppKit and Core Animation. No third-party code. |
| ✅ **Verified, not just claimed** | `make audit` checks entitlements, signatures and imported APIs; `make selftest` proves the sandbox blocks the network and the helper refuses what it should. Both run in CI. |

Details: [SECURITY.md](SECURITY.md) · [PRIVACY.md](PRIVACY.md)

## Requirements

- macOS 14 Sonoma or later (Apple silicon or Intel).
- To build: Xcode 15 or later (Xcode 26 recommended for Liquid Glass), or just
  the Command Line Tools (`xcode-select --install`) for a build for your Mac's
  architecture.

## Build and run

```sh
git clone https://github.com/ALIRAZA47/mardock.git
cd mardock
make install    # builds, copies to /Applications and opens MarDock
```

or `make run` to build and launch from `build/MarDock.app` without installing.

On first launch MarDock offers to bring over the apps from your current Dock,
hide the macOS Dock while it runs, and open at login. MarDock lives in the menu
bar (the dock icon) — that's where Settings and Quit are.

Other tasks:

```sh
make test       # unit tests (engine, validation, protocol)
make audit      # security audit of the built app
make selftest   # end-to-end checks against your system
make clean
```

### Using the build from CI

Every CI run uploads a zipped `MarDock.app` (the **MarDock-app** artifact). It
is signed ad-hoc, not notarized, so macOS will refuse to open it at first:
right-click it and choose **Open**, or clear the download flag with
`xattr -dr com.apple.quarantine MarDock.app`. Building it yourself avoids this.

### Signing for distribution

Local builds are signed ad-hoc, which is fine on the Mac that built them. To
share MarDock, sign it with a Developer ID and notarize it:

```sh
SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" make app
ditto -c -k --keepParent build/MarDock.app build/MarDock.zip
xcrun notarytool submit build/MarDock.zip --keychain-profile <profile> --wait
xcrun stapler staple build/MarDock.app
```

## Getting the macOS Dock back

Turn off **Settings ▸ macOS Dock ▸ Replace the macOS Dock**, choose **Restore
the macOS Dock** in the menu bar menu, or just quit MarDock. If MarDock ever
can't (say, after a crash), run:

```sh
defaults delete com.apple.dock autohide-delay
defaults write com.apple.dock autohide -bool false
killall Dock
```

## How it's built

```
Sources/
  MarDockCore/    Pure Swift: spring physics, the magnification warp, layout and
                  hit-testing engine, auto-hide logic, validated settings, the
                  helper protocol. Unit-tested (also builds on Linux).
  MarDock/        The sandboxed app: Core Animation renderer (Dock/), app state
                  (Model/), helper client and actions (Services/), SwiftUI
                  settings and onboarding (UI/).
  MarDockAgent/   The XPC helper.
App/              Info.plists, entitlements, icon.
scripts/          Bundle + sign, security audit, self-test, icon generator.
```

The interesting part is [`DockEngine`](Sources/MarDockCore/DockEngine.swift): it
owns every spring and produces one `DockFrame` per display refresh, which
[`DockView`](Sources/MarDock/Dock/DockView.swift) maps onto layers. The
magnification math is in [`Magnifier`](Sources/MarDockCore/Magnifier.swift).

## Limitations

- No notification badges on icons: reading them would need Accessibility
  access to the system Dock, which MarDock deliberately doesn't ask for.
- Minimized windows still go to the (hidden) macOS Dock. Turn on **Minimize
  windows into their app's icon** (Settings ▸ macOS Dock) and click the app to
  bring them back.
- macOS doesn't let third-party apps reserve screen space the way the system
  Dock does, so maximised windows can extend under MarDock. Use
  “Automatically hide ▸ When a window overlaps”.
