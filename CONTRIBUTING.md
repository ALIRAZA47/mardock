# Contributing to MarDock

Thanks for wanting to help. MarDock is a small project with one maintainer,
so this guide is short: what kinds of changes are welcome, how to build and
check them, and what keeps the security model intact.

## Ways to help

- **Report a bug** with the
  [bug report form](https://github.com/ALIRAZA47/mardock/issues/new?template=bug_report.yml):
  what you did, what you expected, what happened, and your macOS and MarDock
  versions (Settings ▸ About).
- **Suggest a feature** with the
  [feature request form](https://github.com/ALIRAZA47/mardock/issues/new?template=feature_request.yml).
  For anything bigger than a small change, please open an issue before
  writing code, so the design can be agreed first. MarDock says no to some
  things on purpose; see [What MarDock won't do](#what-mardock-wont-do).
- **Security problems** go through
  [private vulnerability reporting](https://github.com/ALIRAZA47/mardock/security/advisories/new),
  never a public issue. [SECURITY.md](SECURITY.md) has the details.
- **Fix something.** Issues labelled
  [good first issue](https://github.com/ALIRAZA47/mardock/labels/good%20first%20issue)
  and [help wanted](https://github.com/ALIRAZA47/mardock/labels/help%20wanted)
  are a good place to start.

## Building and checking

You need macOS 14 or later and Xcode 15 or later, or its Command Line Tools
(see the README's [Requirements](README.md#requirements)).

```sh
git clone https://github.com/ALIRAZA47/mardock.git
cd mardock
make run        # build build/MarDock.app (ad-hoc signed) and launch it
make test       # unit tests: engine, validation, protocol
make audit      # security audit of the built app
make selftest   # end-to-end checks against your real system
make playground # the dock in your browser, for trying looks and numbers
```

CI runs the same unit tests, build, audit and self-test on every push and
pull request, then takes screenshots and records a tour of the dock on a
macOS runner. Its artifacts (**MarDock-app**, **screenshots**,
**tour-video**) show what a change looks like on a clean Mac.

## Where things are

| Path | What |
| --- | --- |
| `Sources/MarDockCore/` | Pure Swift, unit-tested, also builds on Linux: spring physics, the magnification warp, the layout and hit-testing engine (`DockEngine`), auto-hide, validated settings and the helper protocol (`AgentMessages.swift`). |
| `Sources/MarDock/` | The sandboxed app: the Core Animation renderer (`Dock/`), app state (`Model/`), the helper client and actions (`Services/`), SwiftUI settings and onboarding (`UI/`). |
| `Sources/MarDockAgent/` | The XPC helper: the few privileged operations, strictly validated. |
| `Tests/MarDockCoreTests/` | Unit tests for `MarDockCore`. |
| `App/` | Info.plists, entitlements, the icon. |
| `scripts/` | Build and sign, the security audit, the self-test, CI helpers. |
| `playground/index.html` | A browser port of the engine and the themes' numbers. Keep it in step with `MarDockCore` and `Theme.swift`. |

## What a good change looks like

**It keeps the security model.** This is the part reviews are strictest
about, because it is what MarDock promises its users ([SECURITY.md](SECURITY.md)):

- No third-party dependencies. `Package.swift` has none and stays that way.
- No new entitlements, and no new permissions unless they gate an opt-in extra
  that is off by default, as the existing ones are.
- No networking, no running other programs, and nothing looked up by name
  (`dlsym`, `NSClassFromString`, selectors from strings). `make audit` fails
  if either binary imports such an API or the sources mention one.
- The helper's `AgentRequest` enum is its whole surface. A new operation needs
  a narrow, typed request; validation in `AgentWire.isWellFormed` and again at
  the point of use (a pid must still belong to the app it claims to be, and so
  on); a rate limit; a row in SECURITY.md's table; a self-test showing the
  helper refusing bad input; and a unit test of the message. There is no
  generic "run this" or "write that" operation, and there won't be.
- Every external input (settings files, themes, the Dock's plist, dragged
  files, XPC messages) is bounded and validated, and parsing code comes with
  tests that feed it hostile input.

**It's tested where it can be.** Changes to `MarDockCore` come with unit
tests; `swift test` runs them in seconds without building the app. Changes to
the app itself are checked by building and using it, and by `make selftest`
when they touch the helper, the sandbox or the macOS Dock.

**It stays fast and quiet.** The dock uses practically no CPU when idle:
animation runs off the display's refresh only while something moves. A change
that keeps a timer or display link alive while nothing is moving will be asked
to stop.

**It works for everyone.** VoiceOver can explore and press every dock item,
and Reduce Motion, Reduce Transparency and Increase Contrast are respected.
New UI keeps that true.

**It matches the code around it.** Four-space indentation and Swift's usual
conventions; there is no formatter or linter to run (an
[`.editorconfig`](.editorconfig) is there for editors). Comments explain why,
not what. If you change the engine or a theme's numbers, change the playground
too, so the two stay the same thing.

## What MarDock won't do

Some requests are declined to keep the promises above, however nicely they are
asked: anything that needs network access (update checks, analytics, remote
themes), running scripts or other programs from the dock, reading window
contents or keystrokes beyond the registered hot keys, or asking for
Accessibility, Screen Recording or any other permission by default.

## Pull requests

1. Branch from `main`. One change per pull request keeps reviews quick.
2. Fill in the pull request template: what changed and why, and how you
   checked it.
3. Commit messages have a short, imperative subject that says what changed and
   why ("Keep the pointer's icon still while magnifying"), with any detail in
   the body.
4. Add a line under *Unreleased* in [CHANGELOG.md](CHANGELOG.md) for anything a
   user would notice.
5. CI must pass. `main` only changes through pull requests, and every pull
   request is reviewed by the maintainer ([@ALIRAZA47](https://github.com/ALIRAZA47),
   the code owner) before it is merged. Reviews can take a few days.

By contributing you agree that your contributions are licensed under the
project's [MIT License](LICENSE).

## Releases

The maintainer cuts a release by pushing a `v*` tag, which runs the
**Release** workflow (see the README's [Releases](README.md#releases)). Only
repository admins can create those tags.

## Conduct

This project follows the [Contributor Covenant](CODE_OF_CONDUCT.md). Be kind.
