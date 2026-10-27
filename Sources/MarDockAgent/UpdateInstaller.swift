import AppleArchive
import CryptoKit
import Foundation
import MarDockCore
import System

/// Puts a downloaded release in place of MarDock.app. The updater, which
/// downloaded it, can't write outside its sandbox; this is the one step
/// that needs the helper. Before anything is replaced:
///
///   • the archive is copied into a file only the helper writes, and that
///     copy must match the checksum the release published;
///   • every entry in it must be a plain file or folder inside MarDock.app;
///   • the app in it must be MarDock (same bundle identifier), exactly the
///     version asked for and newer than this one, validly signed with the
///     Hardened Runtime — and, when this copy is signed with a Developer ID,
///     signed by the same developer.
///
/// Only the app this helper is embedded in is ever replaced, never a path
/// from the request.
enum UpdateInstaller {
    static let queue = DispatchQueue(label: "MarDockAgent.update", qos: .userInitiated)

    private static let maxEntries = 10_000

    static func install(archive: FileHandle, version: String, sha256: String, appURL: URL, bundleIdentifier: String) -> AgentReply {
        guard let target = AppVersion(version), Checksums.isSHA256(sha256) else { return .failure(.invalidRequest) }
        guard canReplace(appURL) else {
            agentLog.error("Update refused: MarDock can't be replaced where it is")
            return .failure(.notAllowed)
        }
        guard let current = shortVersion(of: appURL).flatMap(AppVersion.init), target > current else {
            agentLog.error("Update refused: \(version, privacy: .public) isn't newer than this copy")
            return .failure(.notAllowed)
        }

        let files = FileManager.default
        let staging: URL
        do {
            // On the app's own volume, so the swap at the end is a rename.
            staging = try files.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: appURL, create: true)
        } catch {
            agentLog.error("Update failed: no staging folder: \(error.localizedDescription, privacy: .public)")
            return .failure(.failed)
        }
        defer { try? files.removeItem(at: staging) }

        let copy = staging.appendingPathComponent("update.aar")
        guard let digest = copyHashing(archive, to: copy), digest == sha256 else {
            agentLog.error("Update refused: the archive doesn't match its checksum")
            return .failure(.verificationFailed)
        }
        guard entriesStayInside(copy) else {
            agentLog.error("Update refused: the archive holds something other than MarDock.app")
            return .failure(.verificationFailed)
        }
        let extracted = staging.appendingPathComponent("extracted", isDirectory: true)
        guard extract(copy, to: extracted) else {
            agentLog.error("Update failed: couldn't extract the archive")
            return .failure(.failed)
        }
        let newApp = extracted.appendingPathComponent(UpdateArchive.bundleName, isDirectory: true)
        guard isGenuine(newApp, version: target, bundleIdentifier: bundleIdentifier, replacing: appURL) else {
            return .failure(.verificationFailed)
        }
        do {
            _ = try files.replaceItemAt(appURL, withItemAt: newApp, backupItemName: nil, options: [.usingNewMetadataOnly])
        } catch {
            // Most likely macOS's App Management protection, or no write access.
            agentLog.error("Update failed: couldn't replace MarDock: \(error.localizedDescription, privacy: .public)")
            return .failure(.notAllowed)
        }
        agentLog.info("Updated MarDock to \(version, privacy: .public)")
        return .done
    }

    /// Not from a read-only disk image or App Translocation's random
    /// location, and somewhere we may write.
    private static func canReplace(_ app: URL) -> Bool {
        let path = app.path
        guard !path.contains("/AppTranslocation/"), isWritableVolume(app) else { return false }
        return access(app.deletingLastPathComponent().path, W_OK) == 0 && access(path, W_OK) == 0
    }

    private static func isWritableVolume(_ url: URL) -> Bool {
        let readOnly = (try? url.resourceValues(forKeys: [.volumeIsReadOnlyKey]))?.volumeIsReadOnly
        return readOnly == false
    }

    private static func shortVersion(of app: URL) -> String? {
        let plist = app.appendingPathComponent("Contents/Info.plist")
        return (NSDictionary(contentsOf: plist)?["CFBundleShortVersionString"]) as? String
    }

    private static func bundleIdentifier(of app: URL) -> String? {
        let plist = app.appendingPathComponent("Contents/Info.plist")
        return (NSDictionary(contentsOf: plist)?["CFBundleIdentifier"]) as? String
    }

    /// Copies the archive, at most `maxArchiveSize` bytes of it, and returns
    /// the copy's SHA-256.
    private static func copyHashing(_ source: FileHandle, to destination: URL) -> String? {
        var info = stat()
        guard fstat(source.fileDescriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
              info.st_size > 0, Int64(info.st_size) <= UpdateSource.maxArchiveSize,
              FileManager.default.createFile(atPath: destination.path, contents: nil, attributes: [.posixPermissions: 0o600]),
              let output = try? FileHandle(forWritingTo: destination)
        else { return nil }
        defer { try? output.close() }
        var hasher = SHA256()
        var total: Int64 = 0
        do {
            try source.seek(toOffset: 0)
            while let chunk = try source.read(upToCount: 1 << 20), !chunk.isEmpty {
                total += Int64(chunk.count)
                guard total <= UpdateSource.maxArchiveSize else { return nil }
                hasher.update(data: chunk)
                try output.write(contentsOf: chunk)
            }
        } catch {
            return nil
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Reads every entry's header first: nothing is extracted unless all of
    /// them are plain files or folders inside MarDock.app.
    private static func entriesStayInside(_ archive: URL) -> Bool {
        guard let file = ArchiveByteStream.fileStream(path: FilePath(archive.path), mode: .readOnly, options: [], permissions: []),
              let decompressed = ArchiveByteStream.decompressionStream(readingFrom: file),
              let decoder = ArchiveStream.decodeStream(readingFrom: decompressed)
        else { return false }
        defer {
            try? decoder.close()
            try? decompressed.close()
            try? file.close()
        }
        let pathKey = ArchiveHeader.FieldKey("PAT")
        let typeKey = ArchiveHeader.FieldKey("TYP")
        let allowedTypes = [ArchiveHeader.EntryType.regularFile.rawValue, ArchiveHeader.EntryType.directory.rawValue]
        var count = 0
        do {
            while let header = try decoder.readHeader() {
                count += 1
                guard count <= maxEntries,
                      case let .string(_, path)? = header.field(forKey: pathKey), UpdateArchive.isAllowedEntry(path: path),
                      case let .uint(_, type)? = header.field(forKey: typeKey), allowedTypes.contains(UInt32(truncatingIfNeeded: type))
                else { return false }
            }
        } catch {
            return false
        }
        return count > 0
    }

    private static func extract(_ archive: URL, to directory: URL) -> Bool {
        guard (try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)) != nil,
              let file = ArchiveByteStream.fileStream(path: FilePath(archive.path), mode: .readOnly, options: [], permissions: []),
              let decompressed = ArchiveByteStream.decompressionStream(readingFrom: file),
              let decoder = ArchiveStream.decodeStream(readingFrom: decompressed),
              let extractor = ArchiveStream.extractStream(extractingTo: FilePath(directory.path), flags: [.ignoreOperationNotPermitted])
        else { return false }
        defer {
            try? extractor.close()
            try? decoder.close()
            try? decompressed.close()
            try? file.close()
        }
        do {
            _ = try ArchiveStream.process(readingFrom: decoder, writingTo: extractor)
            try extractor.close()
            return true
        } catch {
            return false
        }
    }

    private static func isGenuine(_ app: URL, version: AppVersion, bundleIdentifier: String, replacing current: URL) -> Bool {
        guard self.bundleIdentifier(of: app) == bundleIdentifier, shortVersion(of: app) == version.description else {
            agentLog.error("Update refused: the archive holds a different app or version")
            return false
        }
        let signature = CodeSignature.inspect(bundleAt: app)
        guard signature.isValid, signature.hasHardenedRuntime, signature.identifier == bundleIdentifier else {
            agentLog.error("Update refused: signature \(signature.status, privacy: .public)")
            return false
        }
        // A copy signed with a Developer ID only accepts an update signed by
        // the same developer. (An ad-hoc copy has no developer to compare;
        // there the release's checksum is what vouches for the archive.)
        let installed = CodeSignature.inspect(bundleAt: current)
        if !installed.isAdHoc, installed.teamIdentifier?.isEmpty == false {
            guard let requirement = installed.designatedRequirement,
                  CodeSignature.bundle(at: app, satisfies: requirement)
            else {
                agentLog.error("Update refused: not signed by the same developer")
                return false
            }
        }
        return true
    }
}
