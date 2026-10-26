import AVFoundation
import Foundation

private final class KSPlayerPlaybackRangeRequestState: @unchecked Sendable {
    let completed = DispatchSemaphore(value: 0)

    private let lock = NSLock()
    private var result: Result<(Data, HTTPURLResponse), Error>?

    func finish(_ result: Result<(Data, HTTPURLResponse), Error>) {
        lock.withLock { self.result = result }
        completed.signal()
    }

    func takeResult() -> Result<(Data, HTTPURLResponse), Error>? {
        lock.withLock { result }
    }
}

/// A playback-session range cache for seek-heavy remote media.
///
/// Unlike ``KSPlayerMediaCache``, this cache never persists a whole movie. It
/// keeps a bounded LRU of aligned blocks in memory so badly interleaved MP4
/// tracks can alternate between distant offsets without reopening a remote
/// range for every packet.
final class KSPlayerPlaybackRangeCache: @unchecked Sendable {
    private static let probeLength: Int64 = 256

    private struct Block {
        let data: Data
        var access: UInt64
    }

    let blockSize: Int64
    let capacity: Int64

    private let url: URL
    private let headers: [String: String]
    private let session: URLSession
    private let shouldCancel: @Sendable () -> Bool
    private let condition = NSCondition()
    private var blocks = [Int64: Block]()
    private var loadingBlocks = Set<Int64>()
    private var tasks = [URLSessionDataTask]()
    private var cachedBytesValue: Int64 = 0
    private var accessSequence: UInt64 = 0
    private var hitCount: UInt64 = 0
    private var missCount: UInt64 = 0
    private var preparing = false
    private var preparationResult: Bool?
    private var totalBytesValue: Int64?
    private var mimeTypeValue: String?
    private var cancelled = false

    init(url: URL,
         headers: [String: String],
         blockSize: Int64,
         capacity: Int64,
         shouldCancel: @escaping @Sendable () -> Bool = { false },
         session: URLSession = .shared)
    {
        self.url = url
        self.headers = headers
        self.blockSize = max(1, blockSize)
        self.capacity = max(max(1, blockSize), capacity)
        self.shouldCancel = shouldCancel
        self.session = session
    }

    deinit {
        cancel()
    }

    var cachedByteCount: Int64 {
        condition.lock()
        defer { condition.unlock() }
        return cachedBytesValue
    }

    fileprivate var metadata: (totalBytes: Int64, mimeType: String?)? {
        condition.lock()
        defer { condition.unlock() }
        guard let totalBytesValue else { return nil }
        return (totalBytesValue, mimeTypeValue)
    }

    func prepare() async -> Bool {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async { [weak self] in
                continuation.resume(returning: self?.prepareSync() ?? false)
            }
        }
    }

    func prepareSync() -> Bool {
        guard !shouldCancel() else { return false }
        condition.lock()
        while preparing, preparationResult == nil, !cancelled {
            if shouldCancel() {
                condition.unlock()
                return false
            }
            _ = condition.wait(until: Date().addingTimeInterval(0.05))
        }
        guard !cancelled, !shouldCancel() else {
            condition.unlock()
            return false
        }
        if let preparationResult {
            condition.unlock()
            return preparationResult && !shouldCancel()
        }
        preparing = true
        condition.unlock()

        var success = false
        var totalBytes: Int64?
        var mimeType: String?
        do {
            let result = try request(
                range: KSPlayerMediaCacheRange(start: 0, end: Self.probeLength)
            )
            totalBytes = Self.contentRangeTotal(result.response)
            mimeType = result.response.mimeType
            success = result.response.statusCode == 206 &&
                Self.contentRangeStart(result.response) == 0 &&
                (totalBytes ?? 0) > 0 &&
                Int64(result.data.count) >= min(totalBytes ?? 0, Self.probeLength) &&
                !Self.isHLS(response: result.response, url: url, data: result.data)
        } catch {
            success = false
        }

        let interrupted = shouldCancel()
        condition.lock()
        let finalSuccess = success && !cancelled && !interrupted
        if finalSuccess {
            totalBytesValue = totalBytes
            mimeTypeValue = mimeType
        }
        preparationResult = finalSuccess
        preparing = false
        condition.broadcast()
        condition.unlock()
        return finalSuccess
    }

    func readSync(range: KSPlayerMediaCacheRange) throws -> Data {
        guard range.length > 0 else { return Data() }
        guard !cancellationRequested() else {
            throw KSPlayerPlaybackRangeCacheError.cancelled
        }
        guard prepareSync(), let metadata else {
            throw KSPlayerPlaybackRangeCacheError.unsupported
        }
        let start = max(0, range.start)
        let end = min(metadata.totalBytes, max(start, range.end))
        guard start < end else { return Data() }

        var output = Data()
        output.reserveCapacity(Int(min(end - start, Int64(Int.max))))
        var position = start
        while position < end {
            guard !cancellationRequested() else {
                throw KSPlayerPlaybackRangeCacheError.cancelled
            }
            let blockStart = position / blockSize * blockSize
            let block = try loadBlock(start: blockStart, totalBytes: metadata.totalBytes)
            let localStart = Int(position - blockStart)
            guard localStart < block.count else {
                throw KSPlayerPlaybackRangeCacheError.readFailed
            }
            let count = min(Int(end - position), block.count - localStart)
            guard count > 0 else { throw KSPlayerPlaybackRangeCacheError.readFailed }
            output.append(block.subdata(in: localStart ..< localStart + count))
            position += Int64(count)
        }
        return output
    }

    func makeFFmpegIOContext() -> KSPlayerPlaybackRangeCacheIOContext? {
        guard prepareSync() else { return nil }
        return KSPlayerPlaybackRangeCacheIOContext(cache: self)
    }

    func makeAVAsset() async -> (asset: AVURLAsset, loader: KSPlayerPlaybackRangeCacheResourceLoader)? {
        guard await prepare() else { return nil }
        let loader = KSPlayerPlaybackRangeCacheResourceLoader(cache: self)
        guard let cacheURL = URL(string: "ksplayer-playback-cache://\(UUID().uuidString)") else {
            return nil
        }
        let asset = AVURLAsset(url: cacheURL)
        asset.resourceLoader.setDelegate(
            loader,
            queue: DispatchQueue(label: "KSPlayer.PlaybackRangeCache.\(UUID().uuidString)")
        )
        return (asset, loader)
    }

    func cancel() {
        condition.lock()
        guard !cancelled else {
            condition.unlock()
            return
        }
        cancelled = true
        let activeTasks = tasks
        let summary = (hits: hitCount, misses: missCount, bytes: cachedBytesValue)
        tasks.removeAll()
        condition.broadcast()
        condition.unlock()
        activeTasks.forEach { $0.cancel() }
        if summary.hits > 0 || summary.misses > 0 {
            KSLog(
                level: .warning,
                "Playback range cache closed " +
                    "(hits=\(summary.hits), misses=\(summary.misses), resident=\(summary.bytes))"
            )
        }
    }

    private func loadBlock(start: Int64, totalBytes: Int64) throws -> Data {
        while true {
            guard !cancellationRequested() else {
                throw KSPlayerPlaybackRangeCacheError.cancelled
            }
            condition.lock()
            if cancelled {
                condition.unlock()
                throw KSPlayerPlaybackRangeCacheError.cancelled
            }
            if var block = blocks[start] {
                accessSequence &+= 1
                hitCount &+= 1
                block.access = accessSequence
                blocks[start] = block
                condition.unlock()
                return block.data
            }
            if loadingBlocks.contains(start) {
                _ = condition.wait(until: Date().addingTimeInterval(0.05))
                condition.unlock()
                continue
            }
            loadingBlocks.insert(start)
            missCount &+= 1
            condition.unlock()
            break
        }

        do {
            let end = min(totalBytes, start + blockSize)
            let result = try request(range: KSPlayerMediaCacheRange(start: start, end: end))
            guard !cancellationRequested() else {
                throw KSPlayerPlaybackRangeCacheError.cancelled
            }
            guard result.response.statusCode == 206,
                  Self.contentRangeStart(result.response) == start,
                  Int64(result.data.count) >= end - start
            else {
                throw KSPlayerPlaybackRangeCacheError.invalidRangeResponse
            }
            let data = result.data.prefix(Int(min(Int64(result.data.count), end - start)))
            let blockData = Data(data)

            condition.lock()
            insert(blockData, at: start)
            loadingBlocks.remove(start)
            condition.broadcast()
            condition.unlock()
            return blockData
        } catch {
            condition.lock()
            loadingBlocks.remove(start)
            condition.broadcast()
            condition.unlock()
            throw error
        }
    }

    private func insert(_ data: Data, at start: Int64) {
        if let previous = blocks.removeValue(forKey: start) {
            cachedBytesValue -= Int64(previous.data.count)
        }
        let cost = Int64(data.count)
        while cachedBytesValue + cost > capacity,
              let victim = blocks.min(by: { $0.value.access < $1.value.access })
        {
            blocks[victim.key] = nil
            cachedBytesValue -= Int64(victim.value.data.count)
        }
        guard cost <= capacity else { return }
        accessSequence &+= 1
        blocks[start] = Block(data: data, access: accessSequence)
        cachedBytesValue += cost
    }

    private func request(range: KSPlayerMediaCacheRange) throws -> (data: Data, response: HTTPURLResponse) {
        guard range.length > 0 else { throw KSPlayerPlaybackRangeCacheError.invalidRangeResponse }
        guard !cancellationRequested() else { throw KSPlayerPlaybackRangeCacheError.cancelled }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.httpShouldHandleCookies = false
        headers.forEach { request.setValue($1, forHTTPHeaderField: $0) }
        request.setValue("bytes=\(range.start)-\(range.end - 1)", forHTTPHeaderField: "Range")
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")

        let state = KSPlayerPlaybackRangeRequestState()
        let task = session.dataTask(with: request) { data, response, error in
            if let error {
                state.finish(.failure(error))
            } else if let response = response as? HTTPURLResponse, let data {
                state.finish(.success((data, response)))
            } else {
                state.finish(.failure(KSPlayerPlaybackRangeCacheError.invalidResponse))
            }
        }

        condition.lock()
        if cancelled {
            condition.unlock()
            task.cancel()
            throw KSPlayerPlaybackRangeCacheError.cancelled
        }
        tasks.append(task)
        condition.unlock()
        task.resume()

        let deadline = Date().addingTimeInterval(30)
        while state.completed.wait(timeout: .now() + .milliseconds(50)) != .success {
            if cancellationRequested() {
                task.cancel()
                unregister(task)
                throw KSPlayerPlaybackRangeCacheError.cancelled
            }
            if Date() >= deadline {
                task.cancel()
                unregister(task)
                throw KSPlayerPlaybackRangeCacheError.invalidResponse
            }
        }
        unregister(task)
        guard !cancellationRequested() else {
            throw KSPlayerPlaybackRangeCacheError.cancelled
        }
        guard let result = state.takeResult() else {
            throw KSPlayerPlaybackRangeCacheError.invalidResponse
        }
        return try result.get()
    }

    private func cancellationRequested() -> Bool {
        if shouldCancel() { return true }
        condition.lock()
        let value = cancelled
        condition.unlock()
        return value
    }

    private func unregister(_ task: URLSessionDataTask) {
        condition.lock()
        tasks.removeAll { $0 === task }
        condition.unlock()
    }

    private static func isHLS(response: HTTPURLResponse, url: URL, data: Data) -> Bool {
        let mime = response.mimeType?.lowercased() ?? ""
        if url.path.lowercased().hasSuffix(".m3u8") ||
            mime.contains("mpegurl") || mime.contains("x-mpegurl")
        {
            return true
        }
        guard let prefix = String(data: Data(data.prefix(256)), encoding: .utf8) else {
            return false
        }
        return prefix.contains("#EXTM3U")
    }

    private static func contentRangeStart(_ response: HTTPURLResponse) -> Int64? {
        contentRange(response).flatMap { Int64($0.1) }
    }

    private static func contentRangeTotal(_ response: HTTPURLResponse) -> Int64? {
        guard let value = contentRange(response), value.3 != "*" else { return nil }
        return Int64(value.3)
    }

    private static func contentRange(_ response: HTTPURLResponse) -> (String, String, String, String)? {
        let raw = response.value(forHTTPHeaderField: "Content-Range") ?? ""
        let pattern = #"^\s*bytes\s+(\d+)-(\d+)/(\d+|\*)\s*$"#
        guard let expression = try? NSRegularExpression(pattern: pattern),
              let match = expression.firstMatch(
                  in: raw,
                  range: NSRange(raw.startIndex..., in: raw)
              ),
              match.numberOfRanges == 4
        else { return nil }
        let values = (1 ... 3).compactMap { index -> String? in
            guard let range = Range(match.range(at: index), in: raw) else { return nil }
            return String(raw[range])
        }
        guard values.count == 3 else { return nil }
        return ("bytes", values[0], values[1], values[2])
    }
}

final class KSPlayerPlaybackRangeCacheResourceLoader: NSObject, AVAssetResourceLoaderDelegate, @unchecked Sendable {
    private let cache: KSPlayerPlaybackRangeCache
    private let lock = NSLock()
    private var cancelledRequests = Set<ObjectIdentifier>()
    private var stopped = false

    init(cache: KSPlayerPlaybackRangeCache) {
        self.cache = cache
    }

    deinit {
        cancel()
    }

    func cancel() {
        lock.withLock { stopped = true }
        cache.cancel()
    }

    func resourceLoader(_: AVAssetResourceLoader,
                        shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest) -> Bool
    {
        guard let metadata = cache.metadata else { return false }
        if let info = loadingRequest.contentInformationRequest {
            info.contentType = metadata.mimeType?.contains("mp4") == true
                ? AVFileType.mp4.rawValue
                : "public.data"
            info.contentLength = metadata.totalBytes
            info.isByteRangeAccessSupported = true
        }
        guard let dataRequest = loadingRequest.dataRequest else {
            loadingRequest.finishLoading()
            return true
        }

        let identifier = ObjectIdentifier(loadingRequest)
        DispatchQueue.global(qos: .utility).async { [weak self, weak loadingRequest] in
            guard let self else { return }
            defer { self.removeCancellation(identifier) }
            guard let loadingRequest else { return }
            let requestedStart = max(0, dataRequest.requestedOffset)
            var position = max(requestedStart, dataRequest.currentOffset)
            let requestedEnd = min(
                metadata.totalBytes,
                dataRequest.requestsAllDataToEndOfResource
                    ? metadata.totalBytes
                    : requestedStart + Int64(dataRequest.requestedLength)
            )
            do {
                while position < requestedEnd {
                    if self.isCancelled(identifier) { return }
                    let end = min(requestedEnd, position + self.cache.blockSize)
                    let data = try self.cache.readSync(
                        range: KSPlayerMediaCacheRange(start: position, end: end)
                    )
                    guard !data.isEmpty else {
                        throw KSPlayerPlaybackRangeCacheError.readFailed
                    }
                    dataRequest.respond(with: data)
                    position += Int64(data.count)
                }
                if !self.isCancelled(identifier) {
                    loadingRequest.finishLoading()
                }
            } catch {
                if !self.isCancelled(identifier) {
                    loadingRequest.finishLoading(with: error)
                }
            }
        }
        return true
    }

    func resourceLoader(_: AVAssetResourceLoader,
                        didCancel loadingRequest: AVAssetResourceLoadingRequest)
    {
        lock.withLock { cancelledRequests.insert(ObjectIdentifier(loadingRequest)) }
    }

    private func isCancelled(_ identifier: ObjectIdentifier) -> Bool {
        lock.withLock { stopped || cancelledRequests.contains(identifier) }
    }

    private func removeCancellation(_ identifier: ObjectIdentifier) {
        lock.withLock { cancelledRequests.remove(identifier) }
    }
}

final class KSPlayerPlaybackRangeCacheIOContext: AbstractAVIOContext, @unchecked Sendable {
    private let cache: KSPlayerPlaybackRangeCache
    private var position: Int64 = 0
    private var closed = false

    init(cache: KSPlayerPlaybackRangeCache) {
        self.cache = cache
        super.init()
    }

    override func close() {
        guard !closed else { return }
        closed = true
        cache.cancel()
    }

    deinit {
        close()
    }

    override func read(buffer: UnsafePointer<UInt8>?, size: Int32) -> Int32 {
        guard !closed else { return AVError.eof.code }
        guard let buffer, size > 0 else { return 0 }
        do {
            let data = try cache.readSync(
                range: KSPlayerMediaCacheRange(
                    start: position,
                    end: position + Int64(size)
                )
            )
            guard !data.isEmpty else { return AVError.eof.code }
            data.copyBytes(to: UnsafeMutablePointer(mutating: buffer), count: data.count)
            position += Int64(data.count)
            return Int32(data.count)
        } catch KSPlayerPlaybackRangeCacheError.cancelled {
            return AVError.exit.code
        } catch {
            return AVError.external.code
        }
    }

    override func seek(offset: Int64, whence: Int32) -> Int64 {
        guard !closed else { return -1 }
        switch whence & 0xFFFF {
        case 0:
            position = offset
        case 1:
            position += offset
        case 2:
            guard let total = cache.metadata?.totalBytes else { return -1 }
            position = total + offset
        default:
            return -1
        }
        position = max(0, position)
        return position
    }

    override func fileSize() -> Int64 {
        cache.metadata?.totalBytes ?? -1
    }
}

private enum KSPlayerPlaybackRangeCacheError: LocalizedError {
    case unsupported
    case cancelled
    case invalidResponse
    case invalidRangeResponse
    case readFailed

    var errorDescription: String? {
        switch self {
        case .unsupported: "The playback range cache does not support this resource."
        case .cancelled: "The playback range cache request was cancelled."
        case .invalidResponse: "The playback range cache received an invalid response."
        case .invalidRangeResponse: "The playback range cache received an invalid range response."
        case .readFailed: "The playback range cache could not read the requested bytes."
        }
    }
}
