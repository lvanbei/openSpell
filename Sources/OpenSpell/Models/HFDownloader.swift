import CryptoKit
import Foundation

enum HFDownloadError: LocalizedError {
    case repoNotFound(String)
    case noWeights(String)
    case http(Int, String)
    case shortRead(String)
    case checksumMismatch(String)

    var errorDescription: String? {
        switch self {
        case .repoNotFound(let id): "Hugging Face repo “\(id)” was not found."
        case .noWeights(let id): "“\(id)” doesn't contain MLX weights (*.safetensors)."
        case .http(let code, let file): "Download of \(file) failed (HTTP \(code))."
        case .shortRead(let file): "Download of \(file) was cut off."
        case .checksumMismatch(let file): "\(file) was corrupted during download (checksum mismatch) — please retry."
        }
    }
}

/// Thread-safe byte counter shared by all transfers of one model download.
final class ByteCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Int64
    init(_ initial: Int64 = 0) { value = initial }
    func add(_ n: Int64) { lock.lock(); value += n; lock.unlock() }
    var current: Int64 { lock.lock(); defer { lock.unlock() }; return value }
}

/// Downloads an MLX model snapshot from Hugging Face into a local folder.
///
/// Hugging Face's CDN throttles each connection (≈1 MB/s is common), so large files are split
/// into ranged chunks fetched over several *separate* connections in parallel, written straight
/// into place, resumable chunk-by-chunk, and verified against the repo's SHA-256 afterwards.
final class HFDownloader: @unchecked Sendable {
    struct RemoteFile { let path: String; let size: Int64; let sha256: String? }

    /// Parallel connections per large file.
    static let lanes = 8
    /// Files at least this big use the parallel chunked path (even an 11 MB tokenizer.json
    /// takes ~15 s over one throttled connection).
    static let chunkedThreshold: Int64 = 2 * 1024 * 1024

    /// ~4 chunks per lane keeps every connection busy until the end, within 1–32 MB.
    static func chunkSize(for size: Int64) -> Int64 {
        let target = size / Int64(lanes * 4)
        return min(32 * 1024 * 1024, max(1024 * 1024, target))
    }

    private let lock = NSLock()
    private var cancelled = false
    private var activeChunked: [ChunkedFileDownload] = []
    private var smallTasks: [URLSessionTask] = []

    private let smallSession: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 60
        config.httpMaximumConnectionsPerHost = 6
        return URLSession(configuration: config)
    }()

    static func patternsMatch(_ path: String) -> Bool {
        let name = (path as NSString).lastPathComponent
        if name.hasPrefix(".") { return false }
        return name.hasSuffix(".safetensors") || name.hasSuffix(".json") || name.hasSuffix(".jinja")
            || name == "tokenizer.model"
    }

    static func listFiles(repo: String, revision: String = "main") async throws -> [RemoteFile] {
        let url = URL(string: "https://huggingface.co/api/models/\(repo)/tree/\(revision)?recursive=1")!
        let (data, response) = try await URLSession.shared.data(from: url)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 404 || status == 401 { throw HFDownloadError.repoNotFound(repo) }
        guard (200..<300).contains(status) else { throw HFDownloadError.http(status, "file list") }
        let entries = (try JSONSerialization.jsonObject(with: data) as? [[String: Any]]) ?? []
        let files: [RemoteFile] = entries.compactMap { e in
            guard (e["type"] as? String) == "file", let path = e["path"] as? String,
                  patternsMatch(path) else { return nil }
            let lfs = e["lfs"] as? [String: Any]
            let size = (lfs?["size"] as? NSNumber)?.int64Value ?? (e["size"] as? NSNumber)?.int64Value ?? 0
            return RemoteFile(path: path, size: size, sha256: lfs?["oid"] as? String)
        }
        guard files.contains(where: { $0.path.hasSuffix(".safetensors") }) else { throw HFDownloadError.noWeights(repo) }
        return files
    }

    /// Downloads `repo` into `destination`. `progress` is called with 0…1 (from a background thread).
    func download(repo: String, to destination: URL, revision: String = "main",
                  progress: @escaping @Sendable (Double) -> Void) async throws {
        let files = try await Self.listFiles(repo: repo, revision: revision)
        let total = max(1, files.reduce(Int64(0)) { $0 + $1.size })
        let fm = FileManager.default
        try fm.createDirectory(at: destination, withIntermediateDirectories: true)

        // Skip files that are already complete.
        var pending: [RemoteFile] = []
        var alreadyDone: Int64 = 0
        for file in files {
            let target = destination.appending(path: file.path)
            if let size = (try? fm.attributesOfItem(atPath: target.path))?[.size] as? NSNumber,
               size.int64Value == file.size, file.size > 0 {
                alreadyDone += file.size
            } else {
                pending.append(file)
            }
        }

        let counter = ByteCounter(alreadyDone)
        progress(Double(alreadyDone) / Double(total))

        // Report progress 4× a second while transfers run.
        let reporter = Task.detached {
            while !Task.isCancelled {
                progress(min(1, Double(counter.current) / Double(total)))
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
        defer { reporter.cancel() }

        let small = pending.filter { $0.size < Self.chunkedThreshold }
        let large = pending.filter { $0.size >= Self.chunkedThreshold }

        // Small files (configs, tokenizer): a few at a time.
        try await withThrowingTaskGroup(of: Void.self) { group in
            var iterator = small.makeIterator()
            for _ in 0..<min(4, small.count) {
                guard let file = iterator.next() else { break }
                group.addTask { try await self.downloadSmall(repo: repo, revision: revision, file: file,
                                                             to: destination, counter: counter) }
            }
            while try await group.next() != nil {
                if let file = iterator.next() {
                    group.addTask { try await self.downloadSmall(repo: repo, revision: revision, file: file,
                                                                 to: destination, counter: counter) }
                }
            }
        }

        // Large files (weights): one at a time, each over several parallel connections.
        for file in large {
            try checkCancelled()
            let target = destination.appending(path: file.path)
            try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            let job = ChunkedFileDownload(source: Self.resolveURL(repo: repo, revision: revision, path: file.path),
                                          target: target, size: file.size, sha256: file.sha256,
                                          name: file.path, counter: counter)
            lock.lock(); activeChunked.append(job); let wasCancelled = cancelled; lock.unlock()
            if wasCancelled { job.cancel() }
            try await job.run()
            lock.lock(); activeChunked.removeAll { $0 === job }; lock.unlock()
        }
        progress(1)
    }

    func cancel() {
        lock.lock()
        cancelled = true
        activeChunked.forEach { $0.cancel() }
        smallTasks.forEach { $0.cancel() }
        lock.unlock()
    }

    private func checkCancelled() throws {
        lock.lock(); defer { lock.unlock() }
        if cancelled { throw CancellationError() }
    }

    static func resolveURL(repo: String, revision: String, path: String) -> URL {
        let encoded = path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path
        return URL(string: "https://huggingface.co/\(repo)/resolve/\(revision)/\(encoded)")!
    }

    private func downloadSmall(repo: String, revision: String, file: RemoteFile, to destination: URL,
                               counter: ByteCounter) async throws {
        try checkCancelled()
        let target = destination.appending(path: file.path)
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        let url = Self.resolveURL(repo: repo, revision: revision, path: file.path)

        var lastError: Error = HFDownloadError.shortRead(file.path)
        for attempt in 0..<4 {
            if attempt > 0 { try await Task.sleep(for: .seconds(Double(attempt))) }
            do {
                try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                    let task = smallSession.downloadTask(with: url) { tmp, response, error in
                        if let error { cont.resume(throwing: error); return }
                        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                        guard (200..<300).contains(status), let tmp else {
                            cont.resume(throwing: HFDownloadError.http(status, file.path)); return
                        }
                        do {
                            try? FileManager.default.removeItem(at: target)
                            try FileManager.default.moveItem(at: tmp, to: target)
                            cont.resume()
                        } catch { cont.resume(throwing: error) }
                    }
                    lock.lock(); smallTasks.append(task); let wasCancelled = cancelled; lock.unlock()
                    if wasCancelled { task.cancel() }
                    task.resume()
                }
                counter.add(file.size)
                return
            } catch let error as URLError where error.code == .cancelled {
                throw CancellationError()
            } catch {
                lastError = error
            }
        }
        throw lastError
    }
}

// MARK: - Parallel ranged download of a single file

/// Downloads one large file as fixed-size byte ranges over `HFDownloader.lanes` independent
/// connections (one URLSession per lane — sessions don't share connections, which is what
/// gets around per-connection throttling). Data is written with `pwrite` at each range's
/// offset. Completed chunk indices are saved next to the file so a restart resumes.
final class ChunkedFileDownload: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let source: URL
    private let target: URL
    private let size: Int64
    private let sha256: String?
    private let name: String
    private let counter: ByteCounter

    private var partial: URL { target.appendingPathExtension("partial") }
    private var stateFile: URL { target.appendingPathExtension("partial.json") }

    private let lock = NSLock()
    private var fd: Int32 = -1
    private var resolvedURL: URL?
    private var queue: [Int] = []
    private var done = Set<Int>()
    private var cancelled = false
    private var sessions: [URLSession] = []

    /// Per in-flight task: chunk index, next write offset, remaining bytes, continuation.
    private struct InFlight {
        var chunk: Int
        var offset: Int64
        var remaining: Int64
        var cont: CheckedContinuation<Void, Error>
        var failure: Error?
    }
    private var inFlight: [Int: InFlight] = [:]  // keyed by session-unique task key
    /// Where each chunk's last attempt stopped, so a retry continues instead of starting over.
    private var resumeOffsets: [Int: Int64] = [:]
    private var tasks: [URLSessionTask] = []

    init(source: URL, target: URL, size: Int64, sha256: String?, name: String, counter: ByteCounter) {
        self.source = source
        self.target = target
        self.size = size
        self.sha256 = sha256
        self.name = name
        self.counter = counter
    }

    private var chunkSize: Int64 { HFDownloader.chunkSize(for: size) }
    private var chunkCount: Int { Int((size + chunkSize - 1) / chunkSize) }

    private func range(of chunk: Int) -> (start: Int64, end: Int64) {
        let start = Int64(chunk) * chunkSize
        return (start, min(size, start + chunkSize) - 1)
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let running = tasks
        lock.unlock()
        running.forEach { $0.cancel() }
    }

    func run() async throws {
        let fm = FileManager.default

        // Resume state (only if the partial file is the right size and chunking matches).
        if let data = try? Data(contentsOf: stateFile),
           let saved = try? JSONDecoder().decode(SavedState.self, from: data),
           saved.size == size, saved.chunkSize == chunkSize,
           let attrs = try? fm.attributesOfItem(atPath: partial.path),
           (attrs[.size] as? NSNumber)?.int64Value == size {
            done = Set(saved.done)
        } else {
            try? fm.removeItem(at: partial)
            try? fm.removeItem(at: stateFile)
            fm.createFile(atPath: partial.path, contents: nil)
        }

        let opened = open(partial.path, O_RDWR)
        guard opened >= 0 else { throw CocoaError(.fileWriteUnknown) }
        lock.lock(); fd = opened; lock.unlock()
        defer {
            // Late delegate callbacks check fd under the lock, so they can't write after this.
            lock.lock(); fd = -1; lock.unlock()
            close(opened)
        }
        if ftruncate(opened, off_t(size)) != 0 { throw CocoaError(.fileWriteOutOfSpace) }

        for chunk in done { let r = range(of: chunk); counter.add(r.end - r.start + 1) }
        queue = (0..<chunkCount).filter { !done.contains($0) }

        resolvedURL = try await resolveCDN()

        defer {
            sessions.forEach { $0.invalidateAndCancel() }
            sessions.removeAll()
        }

        if !queue.isEmpty {
            try await withThrowingTaskGroup(of: Void.self) { group in
                for _ in 0..<min(HFDownloader.lanes, queue.count) {
                    let config = URLSessionConfiguration.ephemeral
                    config.timeoutIntervalForRequest = 60
                    config.httpMaximumConnectionsPerHost = 1
                    let session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
                    sessions.append(session)
                    group.addTask { try await self.lane(session) }
                }
                do {
                    try await group.waitForAll()
                } catch {
                    cancel()
                    throw error
                }
            }
        }

        if isCancelled { throw CancellationError() }

        // Integrity check (chunks arrive out of order, so verify the whole file).
        if let sha256 {
            let actual = try Self.sha256(of: partial)
            guard actual == sha256.lowercased() else {
                try? fm.removeItem(at: partial)
                try? fm.removeItem(at: stateFile)
                throw HFDownloadError.checksumMismatch(name)
            }
        }
        try? fm.removeItem(at: target)
        try fm.moveItem(at: partial, to: target)
        try? fm.removeItem(at: stateFile)
    }

    private var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }

    /// Follows Hugging Face's redirect once to get the signed CDN URL (saves a hop per chunk).
    private func resolveCDN() async throws -> URL {
        var request = URLRequest(url: source)
        request.httpMethod = "HEAD"
        let (_, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<400).contains(status) else { throw HFDownloadError.http(status, name) }
        return response.url ?? source
    }

    private func nextChunk() -> Int? {
        lock.lock(); defer { lock.unlock() }
        if cancelled || queue.isEmpty { return nil }
        return queue.removeFirst()
    }

    private func lane(_ session: URLSession) async throws {
        while let chunk = nextChunk() {
            let r = range(of: chunk)
            var offset = r.start
            var attempt = 0
            while true {
                if isCancelled { throw CancellationError() }
                do {
                    offset = try await fetch(chunk: chunk, from: offset, to: r.end, session: session)
                    break
                } catch let error as URLError where error.code == .cancelled {
                    throw CancellationError()
                } catch {
                    attempt += 1
                    if attempt >= 5 { throw error }
                    lock.lock(); if let resume = resumeOffsets[chunk] { offset = resume }; lock.unlock()
                    // Signed CDN links can expire on very long downloads — refresh on auth errors.
                    if case HFDownloadError.http(let code, _) = error, code == 403 || code == 410 {
                        if let fresh = try? await resolveCDN() { lock.lock(); resolvedURL = fresh; lock.unlock() }
                    }
                    try await Task.sleep(for: .seconds(Double(attempt)))
                }
            }
            markDone(chunk)
        }
    }

    /// Fetches [from, to] and returns the next offset (to + 1) on success. On failure, bytes
    /// already written stay counted and the retry continues from where it stopped.
    private func fetch(chunk: Int, from: Int64, to: Int64, session: URLSession) async throws -> Int64 {
        lock.lock(); let url = resolvedURL ?? source; lock.unlock()
        var request = URLRequest(url: url)
        request.setValue("bytes=\(from)-\(to)", forHTTPHeaderField: "Range")

        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            let task = session.dataTask(with: request)
            lock.lock()
            inFlight[task.taskIdentifier &+ ObjectIdentifier(session).hashValue] =
                InFlight(chunk: chunk, offset: from, remaining: to - from + 1, cont: cont, failure: nil)
            tasks.append(task)
            let wasCancelled = cancelled
            lock.unlock()
            if wasCancelled { task.cancel() }
            task.resume()
        }
        return to + 1
    }

    private func key(_ session: URLSession, _ task: URLSessionTask) -> Int {
        task.taskIdentifier &+ ObjectIdentifier(session).hashValue
    }

    private func markDone(_ chunk: Int) {
        lock.lock()
        done.insert(chunk)
        let snapshot = SavedState(size: size, chunkSize: chunkSize, done: Array(done))
        lock.unlock()
        if let data = try? JSONEncoder().encode(snapshot) { try? data.write(to: stateFile, options: .atomic) }
    }

    // MARK: URLSessionDataDelegate

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        // 206 = partial content. A plain 200 would mean the server ignored the range.
        if status == 206 {
            completionHandler(.allow)
        } else {
            lock.lock()
            inFlight[key(session, dataTask)]?.failure = HFDownloadError.http(status, name)
            lock.unlock()
            completionHandler(.cancel)
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        let k = key(session, dataTask)
        lock.lock()
        guard var entry = inFlight[k] else { lock.unlock(); return }
        let writable = min(Int64(data.count), entry.remaining)
        let offset = entry.offset
        entry.offset += writable
        entry.remaining -= writable
        inFlight[k] = entry
        lock.unlock()

        guard writable > 0 else { return }
        // Written under the lock: cheap at network speeds, and guarantees the fd is still open.
        lock.lock()
        let written = fd >= 0 && !cancelled
            ? data.withUnsafeBytes { pwrite(fd, $0.baseAddress, Int(writable), off_t(offset)) }
            : -1
        lock.unlock()
        if written == Int(writable) {
            counter.add(Int64(written))
        } else {
            lock.lock(); inFlight[k]?.failure = CocoaError(.fileWriteUnknown); lock.unlock()
            dataTask.cancel()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let k = key(session, task)
        lock.lock()
        let entry = inFlight.removeValue(forKey: k)
        tasks.removeAll { $0 === task }
        if let entry { resumeOffsets[entry.chunk] = entry.offset }
        lock.unlock()
        guard let entry else { return }

        if let failure = entry.failure {
            entry.cont.resume(throwing: failure)
        } else if let error {
            entry.cont.resume(throwing: error)
        } else if entry.remaining > 0 {
            entry.cont.resume(throwing: HFDownloadError.shortRead(name))
        } else {
            entry.cont.resume()
        }
    }

    // MARK: Helpers

    private struct SavedState: Codable {
        let size: Int64
        let chunkSize: Int64
        let done: [Int]
    }

    private static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let block = try handle.read(upToCount: 8 * 1024 * 1024), !block.isEmpty {
            hasher.update(data: block)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
