// MarDockUpdater — the only part of MarDock that may use the network.
//
// The dock stays offline. When you check for updates (by hand, or once a
// day if you turned that on), the app asks this small XPC service, which:
//
//   • runs in the App Sandbox with exactly one more entitlement than none,
//     outgoing network connections — it can't read your files or the dock's;
//   • only accepts connections from MarDock (the app's identifier, and its
//     Developer ID team when it has one) — and launchd already lets only
//     the app it ships inside look it up;
//   • only fetches this repository's latest-release description, and a
//     release's checksums and archive, over HTTPS from GitHub's hosts, at
//     URLs built from constants and a validated version;
//   • sends nothing about you: no identifiers, no settings, no cookies.
//
// It can't install anything: the helper does that, after checking the
// archive and the app inside it again.

import Foundation
import MarDockCore

let gate = ClientGate.sandboxedService(suffix: ".Updater")
let limiter = RateLimiter()
let listenerDelegate = UpdaterListenerDelegate(gate: gate, limiter: limiter)
let listener = NSXPCListener.service()
listener.delegate = listenerDelegate
listener.resume() // Never returns.
