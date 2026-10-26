import XCTest
@testable import MarDockCore

final class InputValidationTests: XCTestCase {
    func testBundleIdentifiers() {
        for good in ["com.apple.Safari", "org.mozilla.firefox", "com.microsoft.VSCode", "com.foo_bar.app-2"] {
            XCTAssertTrue(InputValidation.isValidBundleIdentifier(good), good)
        }
        for bad in ["", ".com.apple", "com..apple", "com.apple.", "com apple", "com/apple", "com.apple\nx", "çom.apple",
                    String(repeating: "a", count: 256)] {
            XCTAssertFalse(InputValidation.isValidBundleIdentifier(bad), bad)
        }
    }

    func testAppPaths() {
        XCTAssertTrue(InputValidation.isPlausibleAppPath("/Applications/Safari.app"))
        XCTAssertTrue(InputValidation.isPlausibleAppPath("/Applications/Utilities/Terminal.app/"))
        XCTAssertTrue(InputValidation.isPlausibleAppPath("/Users/me/Apps/My App.APP"))
        for bad in ["Applications/Safari.app", "/Applications/../tmp/evil.app", "/Applications/./x.app",
                    "/usr/bin/ls", "/Applications/Safari.app\n", "/", "/Applications/Safari.app/Contents/MacOS/Safari"] {
            XCTAssertFalse(InputValidation.isPlausibleAppPath(bad), bad)
        }
        XCTAssertFalse(InputValidation.isPlausibleAppPath("/" + String(repeating: "a", count: 1100) + ".app"))
    }

    func testDisplayNamesAreCleaned() {
        XCTAssertEqual(InputValidation.sanitizedDisplayName("  Safari \n"), "Safari")
        XCTAssertEqual(InputValidation.sanitizedDisplayName("Bad\u{202E}Name\u{0007}"), "BadName")
        XCTAssertEqual(InputValidation.sanitizedDisplayName(String(repeating: "x", count: 200)).count, InputValidation.maxDisplayNameLength)
    }

    func testFileURLStrings() {
        XCTAssertEqual(InputValidation.appPath(fromFileURLString: "file:///Applications/Safari.app/"), "/Applications/Safari.app")
        XCTAssertEqual(InputValidation.appPath(fromFileURLString: "file:///Applications/Visual%20Studio%20Code.app/"), "/Applications/Visual Studio Code.app")
        XCTAssertNil(InputValidation.appPath(fromFileURLString: "https://example.com/Safari.app"))
        XCTAssertNil(InputValidation.appPath(fromFileURLString: "file:///etc/passwd"))
    }
}

final class SettingsTests: XCTestCase {
    func testRoundTrip() {
        var settings = DockSettings()
        settings.theme = .aurora
        settings.iconSize = 64
        settings.position = .left
        let decoded = DockSettings.decode(settings.encoded())
        XCTAssertEqual(decoded, settings)
    }

    func testMissingAndUnknownValuesFallBackToDefaults() {
        let json = #"{"theme":"vaporwave","iconSize":64,"futureKey":true,"position":7}"#
        let settings = DockSettings.decode(Data(json.utf8))
        XCTAssertEqual(settings.theme, .glass)
        XCTAssertEqual(settings.iconSize, 64)
        XCTAssertEqual(settings.position, .bottom)
    }

    func testNewSettingsDefaultsAndClamping() {
        let s = DockSettings()
        XCTAssertEqual(s.launchShortcut, .controlOption)
        XCTAssertTrue(s.showRecentApps)
        XCTAssertEqual(s.recentAppsCount, 3)
        let decoded = DockSettings.decode(Data(#"{"launchShortcut":"hyper","recentAppsCount":500,"showRecentApps":false}"#.utf8))
        XCTAssertEqual(decoded.launchShortcut, .controlOption)
        XCTAssertEqual(decoded.recentAppsCount, DockSettings.recentAppsRange.upperBound)
        XCTAssertFalse(decoded.showRecentApps)
        XCTAssertEqual(DockSettings.decode(Data(#"{"recentAppsCount":-2}"#.utf8)).recentAppsCount, 1)
    }

    func testOutOfRangeValuesAreClamped() {
        let json = #"{"iconSize":100000,"magnification":-4,"magnificationSpread":0,"revealDelay":99,"animationSpeed":0}"#
        let s = DockSettings.decode(Data(json.utf8))
        XCTAssertEqual(s.iconSize, DockSettings.iconSizeRange.upperBound)
        XCTAssertEqual(s.magnification, DockSettings.magnificationRange.lowerBound)
        XCTAssertEqual(s.magnificationSpread, DockSettings.spreadRange.lowerBound)
        XCTAssertEqual(s.revealDelay, DockSettings.revealDelayRange.upperBound)
        XCTAssertEqual(s.animationSpeed, DockSettings.animationSpeedRange.lowerBound)
    }

    func testGarbageAndOversizedInputGivesDefaults() {
        XCTAssertEqual(DockSettings.decode(Data("not json".utf8)), DockSettings())
        XCTAssertEqual(DockSettings.decode(nil), DockSettings())
        XCTAssertEqual(DockSettings.decode(Data(repeating: 0x20, count: 70_000)), DockSettings())
    }

    func testNonFiniteNumbersAreReplaced() {
        var s = DockSettings()
        s.iconSize = .nan
        s.magnification = .infinity
        let clean = s.sanitized()
        XCTAssertEqual(clean.iconSize, DockSettings.defaults.iconSize)
        XCTAssertEqual(clean.magnification, DockSettings.defaults.magnification)
    }

    func testMetricsShrinkToFitButNeverGrow() {
        var s = DockSettings()
        s.iconSize = 64
        let roomy = DockMetrics.fitting(s, tiles: 10, separators: 2, available: 2000)
        XCTAssertEqual(roomy.iconSize, 64)
        let tight = DockMetrics.fitting(s, tiles: 30, separators: 2, available: 1000)
        XCTAssertLessThan(tight.iconSize, 64)
        let needed = 30 * tight.slot + 2 * tight.separatorWidth + 2 * tight.endPadding
        XCTAssertLessThanOrEqual(needed, 1000)
        let absurd = DockMetrics.fitting(s, tiles: 500, separators: 0, available: 300)
        XCTAssertEqual(absurd.iconSize, 16)
    }

    func testMetricsScaleWithIconSize() {
        var s = DockSettings()
        s.iconSize = 40
        let small = DockMetrics.make(from: s)
        s.iconSize = 96
        let large = DockMetrics.make(from: s)
        XCTAssertLessThan(small.shelfThickness, large.shelfThickness)
        XCTAssertGreaterThan(large.requiredDepth, large.iconSize * large.peakScale)
        s.magnificationEnabled = false
        XCTAssertEqual(DockMetrics.make(from: s).peakScale, 1)
    }
}

final class PinnedAppTests: XCTestCase {
    func testRejectsInvalidPins() {
        XCTAssertNil(PinnedApp(bundleIdentifier: "bad id", path: "/Applications/X.app", name: "X"))
        XCTAssertNil(PinnedApp(bundleIdentifier: "com.x", path: "/tmp/../x.app", name: "X"))
        XCTAssertEqual(PinnedApp(bundleIdentifier: "com.x", path: "/Applications/Xylophone.app", name: "  ")?.name, "Xylophone")
    }

    func testDecodingDropsBadAndDuplicateEntries() throws {
        let json = """
        [
          {"bundleIdentifier":"com.apple.Safari","path":"/Applications/Safari.app","name":"Safari"},
          {"bundleIdentifier":"evil;rm -rf","path":"/Applications/X.app","name":"X"},
          {"bundleIdentifier":"COM.APPLE.SAFARI","path":"/Applications/Safari.app","name":"Dup"},
          {"bundleIdentifier":"com.apple.Notes","path":"/System/Applications/Notes.app"},
          {"nonsense":1}
        ]
        """
        let pins = try XCTUnwrap(PinnedApp.decodeList(Data(json.utf8)))
        XCTAssertEqual(pins.map(\.bundleIdentifier), ["com.apple.Safari", "com.apple.Notes"])
        XCTAssertEqual(pins[1].name, "Notes")
    }

    func testRoundTrip() throws {
        let pins = [PinnedApp(bundleIdentifier: "com.apple.Music", path: "/System/Applications/Music.app", name: "Music")!]
        XCTAssertEqual(PinnedApp.decodeList(PinnedApp.encodeList(pins)), pins)
    }
}

final class ContentBuilderTests: XCTestCase {
    private func running(_ id: String, order: Int, active: Bool = false) -> RunningAppSnapshot {
        RunningAppSnapshot(key: DockIdentity.app(id), bundleIdentifier: id, pid: Int32(100 + order), name: id, isActive: active, isHidden: false, isFinishedLaunching: true, order: order)
    }

    func testOrderingAndSeparators() {
        let pins = [
            PinnedApp(bundleIdentifier: "com.apple.Safari", path: "/Applications/Safari.app", name: "Safari")!,
            PinnedApp(bundleIdentifier: "com.apple.finder", path: "/System/Library/CoreServices/Finder.app", name: "Finder")!,
        ]
        let apps = [running("com.apple.Terminal", order: 2), running("com.apple.Safari", order: 1, active: true), running("com.apple.Notes", order: 0)]
        let entries = DockContentBuilder.build(pins: pins, running: apps)
        XCTAssertEqual(entries.map(\.id), [
            DockIdentity.finder, "app:com.apple.safari",
            DockIdentity.runningSeparator, "app:com.apple.notes", "app:com.apple.terminal",
            DockIdentity.trashSeparator, DockIdentity.trash,
        ])
        XCTAssertTrue(entries[1].spec.isActive)
        XCTAssertTrue(entries[1].spec.isRunning)
        XCTAssertEqual(entries[2].spec.kind, .separator)
    }

    func testHidingRunningAppsAndTrash() {
        let entries = DockContentBuilder.build(pins: [], running: [running("com.apple.Notes", order: 0)], showRunningApps: false, showTrash: false)
        XCTAssertEqual(entries.map(\.id), [DockIdentity.finder])
    }

    func testUserItemsKeepTheirOrderAndKinds() {
        let safari = PinnedApp(bundleIdentifier: "com.apple.Safari", path: "/Applications/Safari.app", name: "Safari")!
        let spacer = DockItem.newSpacer()
        let divider = DockItem.newDivider(title: "Work")
        let entries = DockContentBuilder.build(items: [divider, .app(safari), spacer, .share], running: [], showTrash: false)
        XCTAssertEqual(entries.map(\.id), [DockIdentity.finder, divider.id, safari.id, spacer.id, DockIdentity.share])
        XCTAssertEqual(entries[1].spec.kind, .divider)
        XCTAssertTrue(entries[1].spec.hasLabel)
        XCTAssertEqual(entries[3].spec.kind, .spacer)
        XCTAssertFalse(entries[3].spec.hasLabel)
        XCTAssertEqual(entries[4].spec.kind, .app)
        XCTAssertTrue(entries.dropFirst().allSatisfy(\.isKept))
        XCTAssertFalse(DockContentBuilder.build(items: [.newDivider()], running: [])[1].spec.hasLabel)
    }

    func testRecentAppsFollowRunningOnesAndSkipKeptOrRunningApps() {
        let notes = PinnedApp(bundleIdentifier: "com.apple.Notes", path: "/System/Applications/Notes.app", name: "Notes")!
        let maps = PinnedApp(bundleIdentifier: "com.apple.Maps", path: "/System/Applications/Maps.app", name: "Maps")!
        let books = PinnedApp(bundleIdentifier: "com.apple.iBooksX", path: "/System/Applications/Books.app", name: "Books")!
        let terminal = PinnedApp(bundleIdentifier: "com.apple.Terminal", path: "/System/Applications/Utilities/Terminal.app", name: "Terminal")!
        let entries = DockContentBuilder.build(
            items: [.app(notes)],
            running: [running("com.apple.Terminal", order: 0)],
            recents: [notes, terminal, maps, books],
            recentLimit: 1,
            showTrash: false
        )
        XCTAssertEqual(entries.map(\.id), [DockIdentity.finder, notes.id, DockIdentity.runningSeparator, terminal.id, maps.id])
        XCTAssertTrue(entries[4].isRecent)
        XCTAssertEqual(entries[4].app, maps)
        XCTAssertFalse(entries[4].spec.isRunning)

        let none = DockContentBuilder.build(items: [], running: [], recents: [maps], recentLimit: 0, showTrash: false)
        XCTAssertEqual(none.map(\.id), [DockIdentity.finder])
        let onlyRecents = DockContentBuilder.build(items: [], running: [], recents: [maps], recentLimit: 3, showTrash: false)
        XCTAssertEqual(onlyRecents.map(\.id), [DockIdentity.finder, DockIdentity.runningSeparator, maps.id])
    }

    func testShortcutTargetsAreTheFirstNineApps() {
        let apps = (0..<12).map { PinnedApp(bundleIdentifier: "com.example.a\($0)", path: "/Applications/A\($0).app", name: "A\($0)")! }
        var items = apps.map(DockItem.app)
        items.insert(.newSpacer(), at: 2)
        items.insert(.share, at: 4)
        let targets = DockContentBuilder.build(items: items, running: []).shortcutTargets
        XCTAssertEqual(targets.count, 9)
        XCTAssertEqual(targets.first?.id, DockIdentity.finder)
        XCTAssertEqual(targets.last?.id, apps[7].id)
    }

    func testLaunchingFlagReachesTheSpec() {
        let pin = PinnedApp(bundleIdentifier: "com.apple.Maps", path: "/System/Applications/Maps.app", name: "Maps")!
        let entries = DockContentBuilder.build(pins: [pin], running: [], launching: [pin.id])
        XCTAssertTrue(entries[1].spec.isLaunching)
        XCTAssertFalse(entries[1].spec.isRunning)
    }
}

final class DockItemTests: XCTestCase {
    private let safari = PinnedApp(bundleIdentifier: "com.apple.Safari", path: "/Applications/Safari.app", name: "Safari")!

    func testRoundTripKeepsEveryKind() throws {
        let items: [DockItem] = [.app(safari), .newSpacer(), .newDivider(title: "Work"), .share]
        let decoded = try XCTUnwrap(DockItem.decodeList(DockItem.encodeList(items)))
        XCTAssertEqual(decoded, items)
        XCTAssertEqual(decoded.map(\.app), [safari, nil, nil, nil])
    }

    func testDecodingDropsBadDuplicateAndUnknownEntries() throws {
        let json = """
        [
          {"type":"app","app":{"bundleIdentifier":"com.apple.Safari","path":"/Applications/Safari.app","name":"Safari"}},
          {"type":"app","app":{"bundleIdentifier":"evil;rm","path":"/Applications/X.app"}},
          {"type":"spacer","id":"spacer:ab12"},
          {"type":"spacer","id":"spacer:ab12"},
          {"type":"spacer","id":"spacer:../../etc"},
          {"type":"divider","id":"divider:x1","title":"  Games\\u0007 "},
          {"type":"divider","id":"nope:x1","title":"Bad"},
          {"type":"share"},
          {"type":"share"},
          {"type":"rocket"}
        ]
        """
        let items = try XCTUnwrap(DockItem.decodeList(Data(json.utf8)))
        XCTAssertEqual(items, [.app(safari), .spacer(id: "spacer:ab12"), .divider(id: "divider:x1", title: "Games"), .share])
    }

    func testOldPinListsDecodeAsApps() throws {
        // `pins.v1` held bare apps; the store migrates them by wrapping each one.
        let old = try XCTUnwrap(PinnedApp.decodeList(PinnedApp.encodeList([safari])))
        XCTAssertEqual(old.map(DockItem.app), [.app(safari)])
        XCTAssertNil(DockItem.decodeList(PinnedApp.encodeList([safari])).flatMap { $0.isEmpty ? nil : $0 })
    }

    func testNewTilesGetValidUniqueIDs() {
        let a = DockItem.newSpacer().id, b = DockItem.newSpacer().id
        XCTAssertNotEqual(a, b)
        XCTAssertTrue(DockIdentity.isValidTileID(a, kind: .spacer))
        XCTAssertTrue(DockIdentity.isValidTileID(DockItem.newDivider().id, kind: .divider))
        XCTAssertFalse(DockIdentity.isValidTileID("spacer:", kind: .spacer))
        XCTAssertFalse(DockIdentity.isValidTileID("divider:a b", kind: .divider))
        XCTAssertFalse(DockIdentity.isValidTileID(a, kind: .divider))
    }
}

final class RecentAppsTests: XCTestCase {
    private func app(_ name: String) -> PinnedApp {
        PinnedApp(bundleIdentifier: "com.example." + name, path: "/Applications/\(name).app", name: name)!
    }

    func testMostRecentFirstWithoutDuplicates() {
        var recents = RecentApps()
        recents.note(app("A"))
        recents.note(app("B"))
        recents.note(app("A"))
        XCTAssertEqual(recents.apps.map(\.name), ["A", "B"])
        recents.remove(app("A").id)
        XCTAssertEqual(recents.apps.map(\.name), ["B"])
    }

    func testCapacity() {
        var recents = RecentApps()
        for i in 0..<30 { recents.note(app("App\(i)")) }
        XCTAssertEqual(recents.apps.count, RecentApps.capacity)
        XCTAssertEqual(recents.apps.first?.name, "App29")
    }
}

final class SystemDockTests: XCTestCase {
    func testSchemaAcceptsOnlyKnownKeysTypesAndRanges() {
        XCTAssertTrue(SystemDockSchema.isValid(key: "autohide", value: .bool(true)))
        XCTAssertTrue(SystemDockSchema.isValid(key: "autohide-delay", value: .number(0.2)))
        XCTAssertTrue(SystemDockSchema.isValid(key: "mineffect", value: .string("suck")))
        XCTAssertTrue(SystemDockSchema.isValid(key: "tilesize", value: nil))

        XCTAssertFalse(SystemDockSchema.isValid(key: "persistent-apps", value: .string("x")))
        XCTAssertFalse(SystemDockSchema.isValid(key: "autohide", value: .number(1)))
        XCTAssertFalse(SystemDockSchema.isValid(key: "tilesize", value: .number(4096)))
        XCTAssertFalse(SystemDockSchema.isValid(key: "autohide-delay", value: .number(.nan)))
        XCTAssertFalse(SystemDockSchema.isValid(key: "mineffect", value: .string("explode")))
    }

    func testBatchesRejectDuplicatesAndEmptiness() {
        XCTAssertFalse(SystemDockSchema.isValid([]))
        XCTAssertFalse(SystemDockSchema.isValid([
            SystemDockChange(key: "autohide", value: .bool(true)),
            SystemDockChange(key: "autohide", value: .bool(false)),
        ]))
        XCTAssertTrue(SystemDockSchema.isValid(SystemDockSchema.hideChanges))
    }

    func testRestoreUsesBackupOrRemovesKeys() {
        let restore = SystemDockSchema.restoreChanges(from: ["autohide": .bool(false)])
        XCTAssertEqual(restore, [
            SystemDockChange(key: "autohide", value: .bool(false)),
            SystemDockChange(key: "autohide-delay", value: nil),
        ])
        // A tampered backup is never written back.
        let tampered = SystemDockSchema.restoreChanges(from: ["autohide": .string("rm -rf"), "autohide-delay": .number(-5)])
        XCTAssertEqual(tampered.compactMap(\.value), [])
    }

    func testHiddenDetection() {
        XCTAssertTrue(SystemDockSchema.looksHidden(["autohide": .bool(true), "autohide-delay": .number(1000)]))
        XCTAssertFalse(SystemDockSchema.looksHidden(["autohide": .bool(true), "autohide-delay": .number(0.2)]))
        XCTAssertFalse(SystemDockSchema.looksHidden([:]))
    }

    func testPersistentAppsParser() {
        let plist: [Any] = [
            ["tile-data": ["bundle-identifier": "com.apple.Safari", "file-label": "Safari",
                           "file-data": ["_CFURLString": "file:///Applications/Safari.app/", "_CFURLStringType": 15]]],
            ["tile-data": ["bundle-identifier": "com.apple.Safari", "file-label": "Dup",
                           "file-data": ["_CFURLString": "file:///Applications/Safari.app/"]]],
            ["tile-data": ["bundle-identifier": "x y", "file-data": ["_CFURLString": "file:///Applications/X.app/"]]],
            ["tile-data": ["bundle-identifier": "com.evil", "file-data": ["_CFURLString": "file:///etc/passwd"]]],
            ["tile-type": "spacer-tile"],
            "not a dictionary",
            ["tile-data": ["bundle-identifier": "com.apple.Notes",
                           "file-data": ["_CFURLString": "file:///System/Applications/Notes.app/"]]],
        ]
        let apps = PersistentAppsParser.parse(plist)
        XCTAssertEqual(apps.map(\.bundleIdentifier), ["com.apple.Safari", "com.apple.Notes"])
        XCTAssertEqual(apps[0].path, "/Applications/Safari.app")
        XCTAssertEqual(apps[0].name, "Safari")
        XCTAssertEqual(PersistentAppsParser.parse("garbage"), [])
        XCTAssertEqual(PersistentAppsParser.parse(nil), [])
    }
}

final class AgentWireTests: XCTestCase {
    func testRequestsRoundTrip() throws {
        let requests: [AgentRequest] = [
            .hello(clientVersion: 1),
            .readSystemDock,
            .applySystemDock(changes: SystemDockSchema.hideChanges, restartDock: true),
            .importSystemDockApps,
            .quitApp(pid: 501, bundleIdentifier: "com.apple.Notes", force: false),
            .setHidden(pid: 502, bundleIdentifier: "com.apple.Notes", hidden: true),
            .openTrash,
            .verifyIntegrity,
        ]
        for request in requests {
            let data = try AgentWire.encode(request)
            XCTAssertEqual(try AgentWire.decode(AgentRequest.self, from: data), request)
            XCTAssertTrue(AgentWire.isWellFormed(request))
        }
    }

    func testRepliesRoundTrip() throws {
        let replies: [AgentReply] = [
            .hello(AgentInfo(protocolVersion: 1, isSandboxed: false, clientRequirement: "cdhash H\"00\"")),
            .systemDock(["autohide": .bool(true), "tilesize": .number(48), "mineffect": .string("genie")]),
            .importedApps([ImportedDockApp(bundleIdentifier: "com.apple.Notes", path: "/System/Applications/Notes.app", name: "Notes")]),
            .done,
            .failure(.notAllowed),
        ]
        for reply in replies {
            XCTAssertEqual(try AgentWire.decode(AgentReply.self, from: AgentWire.encode(reply)), reply)
        }
    }

    func testMalformedAndHostileRequestsAreRejected() {
        XCTAssertThrowsError(try AgentWire.decode(AgentRequest.self, from: Data("{\"runShell\":{\"cmd\":\"ls\"}}".utf8)))
        XCTAssertThrowsError(try AgentWire.decode(AgentRequest.self, from: Data(repeating: 0x41, count: AgentWire.maxMessageSize + 1)))
        XCTAssertFalse(AgentWire.isWellFormed(.quitApp(pid: 1, bundleIdentifier: "com.apple.launchd", force: true)))
        XCTAssertFalse(AgentWire.isWellFormed(.quitApp(pid: 400, bundleIdentifier: "../../x", force: false)))
        XCTAssertFalse(AgentWire.isWellFormed(.setHidden(pid: 0, bundleIdentifier: "com.apple.Notes", hidden: true)))
        XCTAssertFalse(AgentWire.isWellFormed(.applySystemDock(changes: [SystemDockChange(key: "persistent-apps", value: .string(""))], restartDock: true)))
        XCTAssertFalse(AgentWire.isWellFormed(.hello(clientVersion: -1)))
    }
}
