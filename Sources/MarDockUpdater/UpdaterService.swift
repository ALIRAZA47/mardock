import CryptoKit
import Foundation
import MarDockCore
import os

let updaterLog = Logger(subsystem: "MarDockUpdater", category: "updater")

final class UpdaterListenerDelegate: NSObject, NSXPCListenerDelegate {
    private let gate: ClientGate
    private let limiter: RateLimiter

    init(gate: ClientGate, limiter: RateLimiter) {
        self.gate = gate
        self.limiter = limiter
    }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        guard let requirement = gate.clientRequirement else {
            updaterLog.error("Refusing connection: \(self.gate.reason, privacy: .public)")
            return false
        }
        connection.setCodeSigningRequirement(requirement)
        connection.exportedInterface = NSXPCInterface(with: MarDockUpdaterXPC.self)
        connection.exportedObject = UpdaterService(limiter: limiter)
        connection.resume()
        return true
    }
}

final class UpdaterService: NSObject, MarDockUpdaterXPC, @unchecked Sendable {
    private let limiter: RateLimiter

    init(limiter: RateLimiter) {
        self.limiter = limiter
    }

    func handle(_ request: Data, reply: @escaping (Data, FileHandle?) -> Void) {
        guard request.count <= AgentWire.maxMessageSize,
              let decoded = try? JSONDecoder().decode(UpdaterRequest.self, from: request),
              UpdaterWire.isWellFormed(decoded)
        else {
            updaterLog.error("Rejected a malformed request")
            reply(Self.encode(.failure(.invalidRequest)), nil)
            return
        }
        DispatchQueue.main.async {
            let allowed: Bool
            switch decoded {
            case .check: allowed = self.limiter.allow("check", every: 5)
            case .download: allowed = self.limiter.allow("download", every: 10)
            }
            guard allowed else {
                reply(Self.encode(.failure(.rateLimited)), nil)
                return
            }
            Task {
                switch decoded {
                case .check:
                    reply(Self.encode(await Self.check()), nil)
                case let .download(version):
                    let (result, archive) = await Self.download(version)
                    reply(Self.encode(result), archive)
                }
            }
        }
    }

    private static func encode(_ reply: UpdaterReply) -> Data {
        (try? AgentWire.encode(reply)) ?? (try? AgentWire.encode(UpdaterReply.failure(.failed))) ?? Data()
    }

    // MARK: Operations

    private static func check() async -> UpdaterReply {
        switch await Transfer.fetch(UpdateSource.latestReleaseURL, limit: Int64(UpdateSource.maxReleaseJSONSize), accept: "application/vnd.github+json") {
        case let .success(data):
            guard let release = ReleaseInfo.parse(githubRelease: data) else { return .failure(.invalidRelease) }
            return .release(release)
        case .failure(.notFound):
            // No release yet.
            return .release(nil)
        case let .failure(failure):
            return .failure(failure)
        }
    }

    /// Downloads a release's archive into this service's own temporary
    /// folder, checks it against the release's checksums, and hands it over
    /// as an open file (the file itself is deleted at once).
    private static func download(_ version: String) async -> (UpdaterReply, FileHandle?) {
        guard let parsed = AppVersion(version) else { return (.failure(.invalidRequest), nil) }
        let name = UpdateSource.archiveName(for: parsed)

        let checksums: Data
        switch await Transfer.fetch(UpdateSource.downloadURL(UpdateSource.checksumsName, version: parsed), limit: Int64(UpdateSource.maxChecksumsSize)) {
        case let .success(data): checksums = data
        case let .failure(failure): return (.failure(failure), nil)
        }
        guard let listing = String(data: checksums, encoding: .utf8),
              let expected = Checksums.sha256(for: name, in: listing)
        else { return (.failure(.invalidRelease), nil) }

        let files = FileManager.default
        let folder = files.temporaryDirectory.appendingPathComponent("Downloads", isDirectory: true)
        try? files.removeItem(at: folder)
        guard (try? files.createDirectory(at: folder, withIntermediateDirectories: true)) != nil else { return (.failure(.failed), nil) }
        let file = folder.appendingPathComponent(name)
        guard files.createFile(atPath: file.path, contents: nil, attributes: [.posixPermissions: 0o600]),
              let output = try? FileHandle(forWritingTo: file)
        else { return (.failure(.failed), nil) }
        defer { try? files.removeItem(at: folder) }

        let result = await Transfer.fetch(UpdateSource.downloadURL(name, version: parsed), limit: UpdateSource.maxArchiveSize, into: output)
        try? output.close()
        let digest: String
        switch result {
        case let .success(data): digest = String(decoding: data, as: UTF8.self)
        case let .failure(failure): return (.failure(failure), nil)
        }
        guard digest == expected else {
            updaterLog.error("The archive for \(version, privacy: .public) doesn't match its checksum")
            return (.failure(.checksumMismatch), nil)
        }
        guard let archive = try? FileHandle(forReadingFrom: file) else { return (.failure(.failed), nil) }
        return (.downloaded(version: parsed.description, sha256: digest), archive)
    }
}

/// One HTTPS request to GitHub, size-capped, that refuses redirects to
/// anywhere but GitHub's own hosts and sends no cookies or identifiers.
private final class Transfer: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let limit: Int64
    private let output: FileHandle?
    private var buffer = Data()
    private var hasher = SHA256()
    private var received: Int64 = 0
    private var failure: UpdaterFailure?
    private var continuation: CheckedContinuation<Result<Data, UpdaterFailure>, Never>?

    private init(limit: Int64, output: FileHandle?) {
        self.limit = limit
        self.output = output
    }

    /// The body (or, when writing `into` a file, the SHA-256 of what was
    /// written, as lowercase hex).
    static func fetch(_ url: URL, limit: Int64, accept: String? = nil, into output: FileHandle? = nil) async -> Result<Data, UpdaterFailure> {
        guard UpdateSource.isAllowed(url) else { return .failure(.invalidRequest) }
        let transfer = Transfer(limit: limit, output: output)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.urlCredentialStorage = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 10 * 60
        configuration.tlsMinimumSupportedProtocolVersion = .TLSv12
        configuration.waitsForConnectivity = false
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        let session = URLSession(configuration: configuration, delegate: transfer, delegateQueue: queue)
        var request = URLRequest(url: url)
        // GitHub wants a user agent; this one says nothing about your Mac.
        request.setValue("MarDock", forHTTPHeaderField: "User-Agent")
        if let accept { request.setValue(accept, forHTTPHeaderField: "Accept") }
        let result = await withCheckedContinuation { continuation in
            queue.addOperation {
                transfer.continuation = continuation
                session.dataTask(with: request).resume()
            }
        }
        session.finishTasksAndInvalidate()
        return result
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        guard UpdateSource.isAllowed(request.url) else {
            updaterLog.error("Refused a redirect to \(request.url?.host ?? "?", privacy: .public)")
            failure = .invalidRelease
            completionHandler(nil)
            task.cancel()
            return
        }
        completionHandler(request)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            failure = status == 404 ? .notFound : .failed
            completionHandler(.cancel)
            return
        }
        guard response.expectedContentLength <= limit else {
            failure = .tooLarge
            completionHandler(.cancel)
            return
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard failure == nil else { return }
        received += Int64(data.count)
        guard received <= limit else {
            failure = .tooLarge
            dataTask.cancel()
            return
        }
        if let output {
            hasher.update(data: data)
            do {
                try output.write(contentsOf: data)
            } catch {
                failure = .failed
                dataTask.cancel()
            }
        } else {
            buffer.append(data)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let result: Result<Data, UpdaterFailure>
        if let failure {
            result = .failure(failure)
        } else if let error = error as? URLError {
            switch error.code {
            case .notConnectedToInternet, .networkConnectionLost, .cannotFindHost, .cannotConnectToHost, .timedOut, .dnsLookupFailed, .dataNotAllowed:
                result = .failure(.offline)
            default:
                result = .failure(.failed)
            }
        } else if error != nil {
            result = .failure(.failed)
        } else if output != nil {
            result = .success(Data(hasher.finalize().map { String(format: "%02x", $0) }.joined().utf8))
        } else {
            result = .success(buffer)
        }
        continuation?.resume(returning: result)
        continuation = nil
    }
}
