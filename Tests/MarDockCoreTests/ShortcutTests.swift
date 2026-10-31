import XCTest
@testable import MarDockCore

final class ShortcutTests: XCTestCase {
    // MARK: Clicks

    private func decide(isApp: Bool = true, action: DoubleClickAction = .shortcuts, hasModifiers: Bool = false, clickCount: Int, hidesOnClick: Bool = false) -> DockClick {
        DockClick.decide(isApp: isApp, action: action, hasModifiers: hasModifiers, clickCount: clickCount, hidesOnClick: hidesOnClick)
    }

    func testAPlainClickActsStraightAway() {
        XCTAssertEqual(decide(clickCount: 1), .activate)
    }

    func testASecondClickIsADoubleClick() {
        XCTAssertEqual(decide(clickCount: 2), .doubleClick)
        XCTAssertEqual(decide(clickCount: 3), .ignore)
    }

    func testAClickThatWouldHideWaitsForASecond() {
        XCTAssertEqual(decide(clickCount: 1, hidesOnClick: true), .activateUnlessDoubled)
        XCTAssertEqual(decide(clickCount: 2, hidesOnClick: true), .doubleClick)
        XCTAssertEqual(decide(action: .off, clickCount: 1, hidesOnClick: true), .activate, "nothing to wait for")
    }

    func testOnlyPlainClicksOnAppsDouble() {
        XCTAssertEqual(decide(isApp: false, clickCount: 2), .activate, "folders and the Trash keep their clicks")
        XCTAssertEqual(decide(hasModifiers: true, clickCount: 2), .activate, "⌥-click hides, ⌘-click reveals")
        XCTAssertEqual(decide(action: .off, clickCount: 2), .activate)
    }

    func testDoubleClickSettingSurvivesAndHasADefault() throws {
        XCTAssertEqual(DockSettings().doubleClickAction, .shortcuts)
        var settings = DockSettings()
        settings.doubleClickAction = .hideOthers
        XCTAssertEqual(DockSettings.decode(settings.encoded()).doubleClickAction, .hideOthers)
        let tampered = Data(#"{"doubleClickAction":"erase"}"#.utf8)
        XCTAssertEqual(DockSettings.decode(tampered).doubleClickAction, .shortcuts)
    }

    // MARK: The user's shortcuts

    func testWebsitesAreTheOnlyLinksAllowed() {
        XCTAssertEqual(UserShortcut.webURL(from: "https://github.com/x")?.absoluteString, "https://github.com/x")
        XCTAssertEqual(UserShortcut.webURL(from: "  example.com "), URL(string: "https://example.com"))
        XCTAssertEqual(UserShortcut.webURL(from: "mailto:me@example.com")?.scheme, "mailto")
        XCTAssertEqual(UserShortcut.webURL(from: "localhost:3000/app"), URL(string: "https://localhost:3000/app"), "a port, not a scheme")
        XCTAssertEqual(UserShortcut.webURL(from: "example.com/a:b"), URL(string: "https://example.com/a:b"), "a colon in the path")
        for bad in ["", "   ", "file:///etc/passwd", "javascript:alert(1)", "x-apple.systempreferences:com.apple.preference.security", "shortcuts://run-shortcut?name=x", "ftp://example.com", "http://", "data:text/html,hello"] {
            XCTAssertNil(UserShortcut.webURL(from: bad), bad)
        }
        XCTAssertEqual(UserShortcut.webURL(from: "tel:123")?.scheme, "https", "reads as a host and port: never a tel: link")
    }

    func testAShortcutNeedsATitleAndAValidAction() throws {
        let url = try XCTUnwrap(URL(string: "https://example.com"))
        XCTAssertNotNil(UserShortcut(title: "Example", action: .website(url)))
        XCTAssertNil(UserShortcut(title: "   ", action: .website(url)))
        XCTAssertNil(UserShortcut(title: "Bad", action: .website(try XCTUnwrap(URL(string: "file:///etc/passwd")))))
        XCTAssertNil(UserShortcut(title: "Bad", action: .shortcut("  ")))
        XCTAssertNil(UserShortcut(title: "Bad", action: .file(path: "../etc", bookmark: Data([1]))))
        XCTAssertNil(UserShortcut(title: "Bad", action: .file(path: "/tmp/x", bookmark: Data())))
        XCTAssertNil(UserShortcut(title: "Bad", action: .file(path: "/tmp/x", bookmark: Data(count: UserShortcut.maxBookmarkBytes + 1))))
    }

    func testListsBelongToAnAppWhateverItsCase() throws {
        let shortcut = try XCTUnwrap(UserShortcut(title: "Run", action: .shortcut("Morning")))
        var list = UserShortcutList()
        list.add(shortcut, toApp: "com.apple.Safari")
        list.add(shortcut, toApp: "com.apple.safari")
        XCTAssertEqual(list.shortcuts(forApp: "COM.APPLE.SAFARI"), [shortcut], "and no shortcut twice")
        list.remove(shortcut.id, fromApp: "com.apple.SAFARI")
        XCTAssertTrue(list.apps.isEmpty)
    }

    func testListsAreBounded() throws {
        var list = UserShortcutList()
        for index in 0..<(UserShortcutList.maxPerApp + 3) {
            list.add(try XCTUnwrap(UserShortcut(title: "\(index)", action: .shortcut("x"))), toApp: "com.example.app")
        }
        XCTAssertEqual(list.shortcuts(forApp: "com.example.app").count, UserShortcutList.maxPerApp)
    }

    func testListsSurviveAndDropWhatDoesntValidate() throws {
        let url = try XCTUnwrap(URL(string: "https://example.com"))
        var list = UserShortcutList()
        list.add(try XCTUnwrap(UserShortcut(title: "Good", action: .website(url))), toApp: "com.example.app")
        XCTAssertEqual(UserShortcutList.decode(list.encoded()), list)

        var json = try XCTUnwrap(String(data: try XCTUnwrap(list.encoded()), encoding: .utf8))
        json = json.replacingOccurrences(of: "https:\\/\\/example.com", with: "file:\\/\\/\\/etc\\/passwd")
        XCTAssertTrue(UserShortcutList.decode(Data(json.utf8)).apps.isEmpty)
        XCTAssertTrue(UserShortcutList.decode(Data("nonsense".utf8)).apps.isEmpty)
    }

    func testBackupsCarryShortcutsAndOlderFilesStillRead() throws {
        var list = UserShortcutList()
        list.add(try XCTUnwrap(UserShortcut(title: "Run", action: .shortcut("Morning"))), toApp: "com.example.app")
        let backup = MarDockBackup(settings: DockSettings(), items: [], themes: [], profiles: nil, icons: [:], userShortcuts: list)
        XCTAssertEqual(try MarDockBackup.decode(try XCTUnwrap(backup.encoded())).userShortcuts, list)

        let older = Data(#"{"format":"\#(MarDockBackup.format)","version":1}"#.utf8)
        XCTAssertTrue(try MarDockBackup.decode(older).userShortcuts.apps.isEmpty)
    }

    // MARK: Apps' own commands

    func testNewAndOpenAreOffered() {
        for title in ["New Window", "New Private Window", "New Tab", "New…", "New Finder Window", "New Folder", "Open…", "Open File…", "Open Location…", "Reopen Closed Tab"] {
            XCTAssertTrue(AppCommandFilter.isOffered(title: title, key: nil, modifiers: nil), title)
        }
    }

    func testAnythingElseInTheMenuIsNot() {
        for title in ["Close Window", "Close All", "Save", "Save As…", "Print…", "Export…", "Quit Safari", "Move to Trash", "Delete", "Empty Trash", "Log Out", "", "News", "Opening Hours"] {
            XCTAssertFalse(AppCommandFilter.isOffered(title: title, key: nil, modifiers: nil), title)
        }
    }

    func testANewItemThatDestroysSomethingIsStillRefused() {
        XCTAssertFalse(AppCommandFilter.isOffered(title: "Open and Delete", key: nil, modifiers: nil))
        XCTAssertFalse(AppCommandFilter.isOffered(title: "New Window and Close Others", key: "N", modifiers: 0))
    }

    func testOtherLanguagesAreFoundByTheirShortcuts() {
        XCTAssertTrue(AppCommandFilter.isOffered(title: "Nueva ventana", key: "n", modifiers: 0))
        XCTAssertTrue(AppCommandFilter.isOffered(title: "Neuer Tab", key: "T", modifiers: 0))
        XCTAssertTrue(AppCommandFilter.isOffered(title: "Nouvelle fenêtre privée", key: "N", modifiers: 1))
        XCTAssertTrue(AppCommandFilter.isOffered(title: "Öffnen …", key: "O", modifiers: 0))
    }

    func testShortcutsThatArentThoseDontCount() {
        XCTAssertFalse(AppCommandFilter.isOffered(title: "Schließen", key: "W", modifiers: 0))
        XCTAssertFalse(AppCommandFilter.isOffered(title: "Something", key: "N", modifiers: 8), "no ⌘")
        XCTAssertFalse(AppCommandFilter.isOffered(title: "Something", key: "N", modifiers: 4), "⌃")
    }

    func testOnlyNewSubmenusAreOpened() {
        XCTAssertTrue(AppCommandFilter.listsNewItems("New Window"))
        XCTAssertFalse(AppCommandFilter.listsNewItems("Open Recent"), "it lists the user's files")
        XCTAssertFalse(AppCommandFilter.listsNewItems("Open With"))
        XCTAssertFalse(AppCommandFilter.listsNewItems("Share"))
    }

    func testKeysAreWrittenAsMenusWriteThem() {
        XCTAssertEqual(AppCommandFilter.keys(key: "n", modifiers: 0), "⌘N")
        XCTAssertEqual(AppCommandFilter.keys(key: "N", modifiers: 1), "⇧⌘N")
        XCTAssertEqual(AppCommandFilter.keys(key: "T", modifiers: 3), "⌥⇧⌘T")
        XCTAssertEqual(AppCommandFilter.keys(key: "K", modifiers: 8), "K")
        XCTAssertEqual(AppCommandFilter.keys(key: nil, modifiers: 0), "")
        XCTAssertEqual(AppCommandFilter.keys(key: "\u{F704}", modifiers: 0), "", "a function key")
    }

    func testCommandsStayWithinTheWireLimits() throws {
        let long = AppCommand(title: String(repeating: "x", count: 400), keys: "⌃⌥⇧⌘NNNNNNNNN", submenu: String(repeating: "y", count: 400))
        XCTAssertTrue(long.isValid)
        XCTAssertFalse(AppCommand(title: "").isValid)
        let reply = AgentReply.commands([AppCommand(title: "New Window", keys: "⌘N")])
        XCTAssertEqual(try AgentWire.decode(AgentReply.self, from: try AgentWire.encode(reply)), reply)
    }
}
