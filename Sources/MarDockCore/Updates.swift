import Foundation

/// A release version such as 1.4 or 1.4.2: up to three numbers, compared
/// numerically (1.10 is newer than 1.9).
public struct AppVersion: Comparable, CustomStringConvertible, Sendable {
    public let components: [Int]

    public init?(_ string: String) {
        let parts = string.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...3).contains(parts.count) else { return nil }
        var components: [Int] = []
        for part in parts {
            guard (1...4).contains(part.count), part.allSatisfy({ $0.isASCII && $0.isNumber }), let value = Int(part) else { return nil }
            components.append(value)
        }
        self.components = components
    }

    public var description: String { components.map(String.init).joined(separator: ".") }

    public static func < (lhs: AppVersion, rhs: AppVersion) -> Bool {
        for i in 0..<3 {
            let a = i < lhs.components.count ? lhs.components[i] : 0
            let b = i < rhs.components.count ? rhs.components[i] : 0
            if a != b { return a < b }
        }
        return false
    }

    public static func == (lhs: AppVersion, rhs: AppVersion) -> Bool {
        !(lhs < rhs) && !(rhs < lhs)
    }
}

/// Where updates come from: this repository's GitHub releases, and nothing
/// else. Every URL the updater fetches is built here from constants and a
/// validated version, never taken from a reply.
public enum UpdateSource {
    public static let owner = "ALIRAZA47"
    public static let repository = "mardock"
    public static let checksumsName = "SHA256SUMS.txt"

    /// The archive the updater installs: an Apple Archive of MarDock.app.
    public static func archiveName(for version: AppVersion) -> String {
        "MarDock-\(version).aar"
    }

    public static var latestReleaseURL: URL {
        URL(string: "https://api.github.com/repos/\(owner)/\(repository)/releases/latest")!
    }

    public static var repositoryPage: URL {
        URL(string: "https://github.com/\(owner)/\(repository)")!
    }

    public static var releasesPage: URL {
        URL(string: "https://github.com/\(owner)/\(repository)/releases")!
    }

    public static func releasePage(for version: AppVersion) -> URL {
        URL(string: "https://github.com/\(owner)/\(repository)/releases/tag/v\(version)")!
    }

    public static func downloadURL(_ name: String, version: AppVersion) -> URL {
        URL(string: "https://github.com/\(owner)/\(repository)/releases/download/v\(version)/\(name)")!
    }

    /// Hosts the release downloads may redirect through (GitHub serves
    /// release files from its own storage hosts). HTTPS only.
    public static let allowedHosts: Set<String> = [
        "api.github.com",
        "github.com",
        "objects.githubusercontent.com",
        "release-assets.githubusercontent.com",
    ]

    public static func isAllowed(_ url: URL?) -> Bool {
        guard let url, url.scheme == "https", let host = url.host?.lowercased() else { return false }
        return allowedHosts.contains(host) && url.user == nil && url.password == nil && (url.port == nil || url.port == 443)
    }

    public static let maxReleaseJSONSize = 1024 * 1024
    public static let maxChecksumsSize = 64 * 1024
    public static let maxArchiveSize: Int64 = 200 * 1024 * 1024
    public static let maxNotesLength = 2000
}

/// What the updater says about the newest release.
public struct ReleaseInfo: Codable, Equatable, Sendable {
    public var version: String
    /// The release notes, as plain text, shortened.
    public var notes: String
    /// Whether the release carries an archive the updater can install (older
    /// releases only have the disk image and zip).
    public var installable: Bool

    public init(version: String, notes: String, installable: Bool) {
        self.version = version
        self.notes = String(notes.prefix(UpdateSource.maxNotesLength))
        self.installable = installable
    }

    public var isValid: Bool {
        AppVersion(version) != nil && notes.count <= UpdateSource.maxNotesLength
    }

    /// Reads GitHub's "latest release" reply. Drafts, pre-releases and tags
    /// that aren't a plain `v1.2.3` are refused.
    public static func parse(githubRelease data: Data) -> ReleaseInfo? {
        struct Release: Decodable {
            struct Asset: Decodable {
                var name: String
                var browser_download_url: String
            }
            var tag_name: String
            var draft: Bool?
            var prerelease: Bool?
            var body: String?
            var assets: [Asset]?
        }
        guard data.count <= UpdateSource.maxReleaseJSONSize,
              let release = try? JSONDecoder().decode(Release.self, from: data),
              release.draft != true, release.prerelease != true,
              release.tag_name.hasPrefix("v"),
              let version = AppVersion(String(release.tag_name.dropFirst())),
              release.tag_name == "v\(version)"
        else { return nil }
        let assets = release.assets ?? []
        func has(_ name: String) -> Bool {
            assets.contains { $0.name == name && $0.browser_download_url == UpdateSource.downloadURL(name, version: version).absoluteString }
        }
        let installable = has(UpdateSource.archiveName(for: version)) && has(UpdateSource.checksumsName)
        let notes = InputValidation.sanitizedNotes(release.body ?? "")
        return ReleaseInfo(version: version.description, notes: notes, installable: installable)
    }
}

/// Reads a `shasum -a 256` listing.
public enum Checksums {
    /// The SHA-256 (lowercase hex) listed for `name`, if exactly one is.
    public static func sha256(for name: String, in listing: String) -> String? {
        var found: [String] = []
        for line in listing.split(whereSeparator: \.isNewline) {
            // "<64 hex>  <name>" (or " *<name>" for binary mode).
            let parts = line.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
            guard parts.count == 2 else { continue }
            var file = parts[1].trimmingCharacters(in: .whitespaces)
            if file.hasPrefix("*") { file.removeFirst() }
            guard file == name else { continue }
            let hash = parts[0].lowercased()
            guard isSHA256(hash) else { return nil }
            found.append(hash)
        }
        return found.count == 1 ? found[0] : nil
    }

    public static func isSHA256(_ string: String) -> Bool {
        string.count == 64 && string.utf8.allSatisfy { (0x30...0x39).contains($0) || (0x61...0x66).contains($0) }
    }
}

/// What an update archive may contain: MarDock.app and what's inside it.
public enum UpdateArchive {
    public static let bundleName = "MarDock.app"

    /// Whether an archive entry's path stays inside MarDock.app.
    public static func isAllowedEntry(path: String) -> Bool {
        guard !path.isEmpty, !path.hasPrefix("/"), path.utf8.count <= 1024 else { return false }
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        guard components.first == Substring(bundleName) else { return false }
        return components.allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }
}

/// Requests the app makes of its updater, which has network access and
/// nothing else: it can look up the newest release and download its archive.
public enum UpdaterRequest: Codable, Equatable, Sendable {
    case check
    /// Downloads this release's archive and checks it against the release's
    /// checksums; the reply carries the archive as an open file.
    case download(version: String)
}

public enum UpdaterReply: Codable, Equatable, Sendable {
    /// The newest release; nil when the repository has none yet.
    case release(ReleaseInfo?)
    case downloaded(version: String, sha256: String)
    case failure(UpdaterFailure)
}

public enum UpdaterFailure: String, Codable, Error, Sendable {
    case invalidRequest
    case rateLimited
    case offline
    case notFound
    case invalidRelease
    case tooLarge
    case checksumMismatch
    case failed
}

public enum UpdaterWire {
    public static func isWellFormed(_ request: UpdaterRequest) -> Bool {
        switch request {
        case .check: return true
        case let .download(version): return AppVersion(version)?.description == version
        }
    }
}

#if canImport(ObjectiveC)
/// The updater's XPC interface: bounded JSON in, JSON out, plus the
/// downloaded archive as an open file.
@objc public protocol MarDockUpdaterXPC {
    func handle(_ request: Data, reply: @escaping (Data, FileHandle?) -> Void)
}
#endif
