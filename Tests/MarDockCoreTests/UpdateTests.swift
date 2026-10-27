import XCTest
@testable import MarDockCore

final class UpdateTests: XCTestCase {
    func testVersionsCompareNumerically() throws {
        func v(_ s: String) throws -> AppVersion { try XCTUnwrap(AppVersion(s), s) }
        XCTAssertLessThan(try v("1.9"), try v("1.10"))
        XCTAssertLessThan(try v("1.0.0"), try v("1.0.1"))
        XCTAssertLessThan(try v("0.9.9"), try v("1"))
        XCTAssertEqual(try v("1.2"), try v("1.2.0"))
        XCTAssertFalse(try v("2.0") < v("1.99.99"))
        XCTAssertEqual(try v("1.02").description, "1.2")
        for bad in ["", "v1.0", "1.", ".1", "1..2", "1.2.3.4", "1.2-beta", "１.２", "12345.0", "1.2 ", "-1.0"] {
            XCTAssertNil(AppVersion(bad), bad)
        }
    }

    func testChecksumListing() {
        let a = String(repeating: "a", count: 64), b = String(repeating: "b", count: 64)
        let listing = "\(a)  MarDock-1.2.0.dmg\n\(b)  MarDock-1.2.0.aar\n"
        XCTAssertEqual(Checksums.sha256(for: "MarDock-1.2.0.aar", in: listing), b)
        XCTAssertEqual(Checksums.sha256(for: "MarDock-1.2.0.aar", in: "\(b.uppercased()) *MarDock-1.2.0.aar"), b)
        XCTAssertNil(Checksums.sha256(for: "MarDock-1.2.0.zip", in: listing))
        // Listed twice, or with a malformed hash: refuse rather than guess.
        XCTAssertNil(Checksums.sha256(for: "MarDock-1.2.0.aar", in: listing + "\(a)  MarDock-1.2.0.aar\n"))
        XCTAssertNil(Checksums.sha256(for: "MarDock-1.2.0.aar", in: "xyz  MarDock-1.2.0.aar"))
    }

    func testArchiveEntriesStayInsideTheApp() {
        for good in ["MarDock.app", "MarDock.app/Contents", "MarDock.app/Contents/MacOS/MarDock", "MarDock.app/Contents/Resources/My Icon.icns"] {
            XCTAssertTrue(UpdateArchive.isAllowedEntry(path: good), good)
        }
        for bad in ["", "/MarDock.app", "Other.app/x", "MarDock.app/../evil", "MarDock.app/./x", "MarDock.app//x",
                    "MarDock.app/", "MarDock.appx/Contents", "../MarDock.app", "MarDock.app/Contents/.."] {
            XCTAssertFalse(UpdateArchive.isAllowedEntry(path: bad), bad)
        }
    }

    private func release(tag: String, assets: [String], draft: Bool = false, prerelease: Bool = false, body: String = "Notes", urlTag: String? = nil) -> Data {
        let list = assets.map { name in
            ["name": name, "browser_download_url": "https://github.com/ALIRAZA47/mardock/releases/download/\(urlTag ?? tag)/\(name)"]
        }
        let json: [String: Any] = ["tag_name": tag, "draft": draft, "prerelease": prerelease, "body": body, "assets": list]
        return try! JSONSerialization.data(withJSONObject: json)
    }

    func testReleaseParsing() throws {
        let full = try XCTUnwrap(ReleaseInfo.parse(githubRelease: release(tag: "v1.3.0", assets: ["MarDock-1.3.0.dmg", "MarDock-1.3.0.aar", "SHA256SUMS.txt"])))
        XCTAssertEqual(full.version, "1.3.0")
        XCTAssertTrue(full.installable)

        // Older releases (no archive) can be announced, not installed.
        let old = try XCTUnwrap(ReleaseInfo.parse(githubRelease: release(tag: "v1.0.0", assets: ["MarDock-1.0.0.dmg", "SHA256SUMS.txt"])))
        XCTAssertFalse(old.installable)

        // An asset that points anywhere else doesn't count.
        let elsewhere = try XCTUnwrap(ReleaseInfo.parse(githubRelease: release(tag: "v1.3.0", assets: ["MarDock-1.3.0.aar", "SHA256SUMS.txt"], urlTag: "v9.9.9")))
        XCTAssertFalse(elsewhere.installable)

        XCTAssertNil(ReleaseInfo.parse(githubRelease: release(tag: "v1.3.0", assets: [], draft: true)))
        XCTAssertNil(ReleaseInfo.parse(githubRelease: release(tag: "v1.3.0", assets: [], prerelease: true)))
        for tag in ["1.3.0", "v1.3.0-beta", "v01.3", "nightly", "v1.3.0/../x"] {
            XCTAssertNil(ReleaseInfo.parse(githubRelease: release(tag: tag, assets: [])), tag)
        }
        XCTAssertNil(ReleaseInfo.parse(githubRelease: Data("not json".utf8)))

        let noisy = try XCTUnwrap(ReleaseInfo.parse(githubRelease: release(tag: "v1.3.0", assets: [], body: "Fixes\u{202E}\u{0007}\n" + String(repeating: "x", count: 5000))))
        XCTAssertEqual(noisy.notes.count, UpdateSource.maxNotesLength)
        XCTAssertTrue(noisy.notes.hasPrefix("Fixes\nxxx"))
    }

    func testOnlyGitHubOverHTTPS() {
        XCTAssertTrue(UpdateSource.isAllowed(UpdateSource.latestReleaseURL))
        XCTAssertTrue(UpdateSource.isAllowed(URL(string: "https://release-assets.githubusercontent.com/github-production-release-asset/1")))
        for bad in ["http://github.com/x", "https://github.com.evil.com/x", "https://evil.com/github.com", "https://user@github.com/x",
                    "https://github.com:8443/x", "file:///etc/passwd"] {
            XCTAssertFalse(UpdateSource.isAllowed(URL(string: bad)), bad)
        }
    }

    func testUpdaterMessages() throws {
        for request: UpdaterRequest in [.check, .download(version: "1.3.0")] {
            XCTAssertEqual(try AgentWire.decode(UpdaterRequest.self, from: AgentWire.encode(request)), request)
            XCTAssertTrue(UpdaterWire.isWellFormed(request))
        }
        XCTAssertFalse(UpdaterWire.isWellFormed(.download(version: "1.3.0/../../x")))
        XCTAssertFalse(UpdaterWire.isWellFormed(.download(version: "1.03")))
        let replies: [UpdaterReply] = [
            .release(nil),
            .release(ReleaseInfo(version: "1.3.0", notes: "Notes", installable: true)),
            .downloaded(version: "1.3.0", sha256: String(repeating: "a", count: 64)),
            .failure(.checksumMismatch),
        ]
        for reply in replies {
            XCTAssertEqual(try AgentWire.decode(UpdaterReply.self, from: AgentWire.encode(reply)), reply)
        }
    }
}
