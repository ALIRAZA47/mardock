// MarDockAgent — the privileged half of MarDock.
//
// MarDock's dock runs in the App Sandbox, which (rightly) stops it from
// quitting other apps or touching another app's preferences. This XPC service
// does those few things on its behalf, and nothing else:
//
//   • it only accepts connections from code that satisfies the designated
//     requirement of the exact app bundle it ships inside;
//   • it only understands the requests in `AgentRequest`, each validated
//     against strict allowlists before anything happens;
//   • it never runs shell commands, loads code, or touches the network.

import AppKit
import Foundation
import MarDockCore

// Check in with the window server and Launch Services as a background-only
// app (no Dock icon, no menus, no windows). Hiding other apps requires the
// caller to be a registered app.
MainActor.assumeIsolated {
    _ = NSApplication.shared.setActivationPolicy(.prohibited)
}

let gate = ClientGate()
let limiter = RateLimiter()
let listenerDelegate = AgentListenerDelegate(gate: gate, limiter: limiter)
let listener = NSXPCListener.service()
listener.delegate = listenerDelegate
listener.resume() // Never returns.
