# MarDock — common tasks. Requires Xcode 15 or later (or its command line tools).

.PHONY: app run install test audit selftest icon playground clean

## Build build/MarDock.app (universal, Hardened Runtime, ad-hoc signed).
## Set SIGN_IDENTITY="Developer ID Application: …" to sign for distribution.
app:
	scripts/build-app.sh

## Build and launch.
run: app
	open build/MarDock.app

## Copy to /Applications (recommended: "Open at login" works best from there).
install: app
	rm -rf /Applications/MarDock.app
	ditto build/MarDock.app /Applications/MarDock.app
	open /Applications/MarDock.app

## Unit tests for the engine, validation and protocol.
test:
	swift test

## Check entitlements, signatures and imported APIs of the built app.
audit: app
	scripts/security-audit.sh build/MarDock.app

## End-to-end checks against the real system (sandbox, helper, launch/quit).
selftest:
	OUTPUT_DIR=build/selftest SCRATCH=.build-selftest ARCHS="$$(uname -m)" \
	SWIFT_FLAGS="-Xswiftc -DMARDOCK_SELFTEST" scripts/build-app.sh
	scripts/ci-selftest.sh build/selftest/MarDock.app

## Try the dock in a browser: the same engine and theme numbers, with tunable settings.
playground:
	open playground/index.html

## Redraw the app icon (needs Python 3 with Pillow).
icon:
	python3 scripts/make-icon.py

clean:
	rm -rf .build .build-selftest build
