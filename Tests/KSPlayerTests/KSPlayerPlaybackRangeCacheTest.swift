@testable import KSPlayer
import Foundation
import XCTest

private final class KSPlayerPlaybackRangeFixtureURLProtocol: URLProtocol {
    static let totalLength = 128 * 1024 * 1024
    static let lock = NSLock()
    static var requestedRanges = [Range<Int64>]()
    static var supportsRanges = true
    static var reportsWrongRangeStart = false
    static var isHLS = false
    static var stallsRequests = false
    static var requestStarted = DispatchSemaphore(value: 0)

    static func reset() {
        lock.withLock {
            requestedRanges.removeAll()
            supportsRanges = true
            reportsWrongRangeStart = false
            isHLS = false
            stallsRequests = false
            requestStarted = DispatchSemaphore(value: 0)
        }
    }

    override class func canInit(with _: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let fixture = Self.lock.withLock {
            (
                supportsRanges: Self.supportsRanges,
                reportsWrongRangeStart: Self.reportsWrongRangeStart,
                isHLS: Self.isHLS,
                stallsRequests: Self.stallsRequests,
                requestStarted: Self.requestStarted
            )
        }
        if fixture.stallsRequests {
            fixture.requestStarted.signal()
            return
        }
        let supportsRanges = fixture.supportsRanges
        guard supportsRanges else {
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: [
                    "Content-Length": "\(Self.totalLength)",
                    "Content-Type": "video/mp4",
                ]
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(repeating: 0, count: 1))
            client?.urlProtocolDidFinishLoading(self)
            return
        }

        let rawRange = request.value(forHTTPHeaderField: "Range") ?? "bytes=0-0"
        let value = rawRange.replacingOccurrences(of: "bytes=", with: "")
        let parts = value.split(separator: "-", omittingEmptySubsequences: false)
        let start = max(0, Int64(parts.first ?? "0") ?? 0)
        let requestedEnd = parts.count > 1 ? Int64(parts[1]) : nil
        let end = min(Int64(Self.totalLength - 1), requestedEnd ?? Int64(Self.totalLength - 1))
        let range = start ..< max(start, end + 1)
        Self.lock.withLock { Self.requestedRanges.append(range) }

        var data = Data(repeating: UInt8(truncatingIfNeeded: start), count: Int(range.count))
        if fixture.isHLS, range.lowerBound == 0 {
            let marker = Data("#EXTM3U\n".utf8)
            data.replaceSubrange(0 ..< min(data.count, marker.count), with: marker.prefix(data.count))
        }
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 206,
            httpVersion: nil,
            headerFields: [
                "Content-Range": "bytes \(range.lowerBound + (fixture.reportsWrongRangeStart ? 1 : 0))-\(range.upperBound - 1)/\(Self.totalLength)",
                "Content-Length": "\(data.count)",
                "Content-Type": "video/mp4",
            ]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private final class KSPlayerPlaybackRangePreparationState: @unchecked Sendable {
    let completed = DispatchSemaphore(value: 0)

    private let lock = NSLock()
    private var result: Bool?

    func finish(_ result: Bool) {
        lock.withLock { self.result = result }
        completed.signal()
    }

    func takeResult() -> Bool? {
        lock.withLock { result }
    }
}

private final class KSPlayerPlaybackRangeCancellationState: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    func cancel() {
        lock.withLock { cancelled = true }
    }

    func isCancelled() -> Bool {
        lock.withLock { cancelled }
    }
}

private final class KSPlayerPlaybackRangeReadState: @unchecked Sendable {
    let completed = DispatchSemaphore(value: 0)

    private let lock = NSLock()
    private var result: Int32?

    func finish(_ result: Int32) {
        lock.withLock { self.result = result }
        completed.signal()
    }

    func takeResult() -> Int32? {
        lock.withLock { result }
    }
}

final class KSPlayerPlaybackRangeCacheTest: XCTestCase {
    private let blockSize = Int64(4 * 1024 * 1024)
    private let capacity = Int64(32 * 1024 * 1024)

    override func setUp() {
        super.setUp()
        KSPlayerPlaybackRangeFixtureURLProtocol.reset()
    }

    func testPathologicalInterleaveUsesBoundedBlockRequests() throws {
        let cache = makeCache()
        XCTAssertTrue(cache.prepareSync())

        let readSize = Int64(32 * 1024)
        for index in 0 ..< 512 {
            let audio = Int64(18 * 1024 * 1024 + index * 1024)
            let video = Int64(30 * 1024 * 1024 + index * 32 * 1024)
            XCTAssertEqual(
                try cache.readSync(range: KSPlayerMediaCacheRange(start: audio, end: audio + readSize)).count,
                Int(readSize)
            )
            XCTAssertEqual(
                try cache.readSync(range: KSPlayerMediaCacheRange(start: video, end: video + readSize)).count,
                Int(readSize)
            )
        }

        for index in (0 ..< 512).reversed() {
            let audio = Int64(18 * 1024 * 1024 + index * 1024)
            let video = Int64(30 * 1024 * 1024 + index * 32 * 1024)
            _ = try cache.readSync(range: KSPlayerMediaCacheRange(start: audio, end: audio + readSize))
            _ = try cache.readSync(range: KSPlayerMediaCacheRange(start: video, end: video + readSize))
        }

        let requests = KSPlayerPlaybackRangeFixtureURLProtocol.lock.withLock {
            KSPlayerPlaybackRangeFixtureURLProtocol.requestedRanges
        }
        XCTAssertLessThanOrEqual(requests.count, 7)
        XCTAssertTrue(requests.dropFirst().allSatisfy { Int64($0.count) <= blockSize })
        XCTAssertLessThanOrEqual(cache.cachedByteCount, capacity)
    }

    func testNonRangeServerIsRejected() {
        KSPlayerPlaybackRangeFixtureURLProtocol.lock.withLock {
            KSPlayerPlaybackRangeFixtureURLProtocol.supportsRanges = false
        }
        XCTAssertFalse(makeCache().prepareSync())
    }

    func testMalformedRangeResponseIsRejected() {
        KSPlayerPlaybackRangeFixtureURLProtocol.lock.withLock {
            KSPlayerPlaybackRangeFixtureURLProtocol.reportsWrongRangeStart = true
        }
        XCTAssertFalse(makeCache().prepareSync())
    }

    func testHLSResponseIsRejected() {
        KSPlayerPlaybackRangeFixtureURLProtocol.lock.withLock {
            KSPlayerPlaybackRangeFixtureURLProtocol.isHLS = true
        }
        XCTAssertFalse(makeCache().prepareSync())
    }

    func testLeastRecentlyUsedBlocksStayWithinCapacity() throws {
        let cache = makeCache(blockSize: blockSize, capacity: 2 * blockSize)
        XCTAssertTrue(cache.prepareSync())

        _ = try cache.readSync(range: KSPlayerMediaCacheRange(start: 0, end: 32 * 1024))
        _ = try cache.readSync(range: KSPlayerMediaCacheRange(start: blockSize, end: blockSize + 32 * 1024))
        _ = try cache.readSync(range: KSPlayerMediaCacheRange(start: 0, end: 32 * 1024))
        _ = try cache.readSync(range: KSPlayerMediaCacheRange(start: 2 * blockSize, end: 2 * blockSize + 32 * 1024))
        _ = try cache.readSync(range: KSPlayerMediaCacheRange(start: blockSize, end: blockSize + 32 * 1024))

        let requests = KSPlayerPlaybackRangeFixtureURLProtocol.lock.withLock {
            KSPlayerPlaybackRangeFixtureURLProtocol.requestedRanges
        }
        XCTAssertEqual(requests.count, 5)
        XCTAssertLessThanOrEqual(cache.cachedByteCount, 2 * blockSize)
    }

    func testReadAtEndOfFileReturnsOnlyAvailableBytes() throws {
        let cache = makeCache()
        let start = Int64(KSPlayerPlaybackRangeFixtureURLProtocol.totalLength - 2)
        let data = try cache.readSync(
            range: KSPlayerMediaCacheRange(start: start, end: start + 32 * 1024)
        )
        XCTAssertEqual(data.count, 2)
    }

    func testFFmpegIOContextReusesAlignedBlock() throws {
        let context = try XCTUnwrap(makeCache().makeFFmpegIOContext())
        defer { context.close() }
        let firstOffset = Int64(18 * 1024 * 1024)
        let secondOffset = firstOffset + 64 * 1024
        var buffer = [UInt8](repeating: 0, count: 32 * 1024)

        XCTAssertEqual(context.seek(offset: firstOffset, whence: 0), firstOffset)
        XCTAssertEqual(
            buffer.withUnsafeMutableBufferPointer {
                context.read(buffer: $0.baseAddress, size: Int32($0.count))
            },
            Int32(buffer.count)
        )
        XCTAssertEqual(context.seek(offset: secondOffset, whence: 0), secondOffset)
        XCTAssertEqual(
            buffer.withUnsafeMutableBufferPointer {
                context.read(buffer: $0.baseAddress, size: Int32($0.count))
            },
            Int32(buffer.count)
        )

        let requests = KSPlayerPlaybackRangeFixtureURLProtocol.lock.withLock {
            KSPlayerPlaybackRangeFixtureURLProtocol.requestedRanges
        }
        XCTAssertEqual(requests, [0 ..< 256, 16 * 1024 * 1024 ..< 20 * 1024 * 1024])
    }

    func testFFmpegIOContextReturnsShortReadThenEndOfFile() throws {
        let context = try XCTUnwrap(makeCache().makeFFmpegIOContext())
        defer { context.close() }
        let start = Int64(KSPlayerPlaybackRangeFixtureURLProtocol.totalLength - 2)
        XCTAssertEqual(context.seek(offset: start, whence: 0), start)

        var buffer = [UInt8](repeating: 0, count: 32 * 1024)
        let finalRead = buffer.withUnsafeMutableBufferPointer {
            context.read(buffer: $0.baseAddress, size: Int32($0.count))
        }
        let eofRead = buffer.withUnsafeMutableBufferPointer {
            context.read(buffer: $0.baseAddress, size: Int32($0.count))
        }
        XCTAssertEqual(finalRead, 2)
        XCTAssertEqual(eofRead, AVError.eof.code)
    }

    func testExternalInterruptStopsBlockedFFmpegRead() throws {
        let interruption = KSPlayerPlaybackRangeCancellationState()
        let cache = makeCache(shouldCancel: { interruption.isCancelled() })
        let context = try XCTUnwrap(cache.makeFFmpegIOContext())
        defer { context.close() }
        let requestStarted = KSPlayerPlaybackRangeFixtureURLProtocol.lock.withLock {
            KSPlayerPlaybackRangeFixtureURLProtocol.stallsRequests = true
            return KSPlayerPlaybackRangeFixtureURLProtocol.requestStarted
        }
        let read = KSPlayerPlaybackRangeReadState()
        XCTAssertEqual(context.seek(offset: 2 * blockSize, whence: 0), 2 * blockSize)

        DispatchQueue.global(qos: .utility).async {
            var buffer = [UInt8](repeating: 0, count: 32 * 1024)
            read.finish(
                buffer.withUnsafeMutableBufferPointer {
                    context.read(buffer: $0.baseAddress, size: Int32($0.count))
                }
            )
        }
        guard requestStarted.wait(timeout: .now() + 1) == .success else {
            XCTFail("The blocking fixture request did not start.")
            return
        }

        interruption.cancel()
        XCTAssertEqual(read.completed.wait(timeout: .now() + 1), .success)
        XCTAssertEqual(read.takeResult(), AVError.exit.code)
    }

    func testFFmpegCacheProtocolWrapsHttpOnlyWithoutCustomIO() throws {
        let remote = try XCTUnwrap(URL(string: "https://fixture.invalid/video.mp4?token=1"))
        XCTAssertEqual(
            MEPlayerItem.inputURLStrings(
                for: remote,
                playbackRangeCacheEnabled: true,
                hasCustomIO: false
            ),
            [
                "cache:https://fixture.invalid/video.mp4?token=1",
                "https://fixture.invalid/video.mp4?token=1",
            ]
        )
        XCTAssertEqual(
            MEPlayerItem.inputURLStrings(
                for: remote,
                playbackRangeCacheEnabled: false,
                hasCustomIO: false
            ),
            [remote.absoluteString]
        )
        XCTAssertEqual(
            MEPlayerItem.inputURLStrings(
                for: remote,
                playbackRangeCacheEnabled: true,
                hasCustomIO: true
            ),
            [remote.absoluteString]
        )
        let local = URL(fileURLWithPath: "/tmp/video.mp4")
        XCTAssertEqual(
            MEPlayerItem.inputURLStrings(
                for: local,
                playbackRangeCacheEnabled: true,
                hasCustomIO: false
            ),
            [local.path]
        )
    }

    func testCancelledCacheRejectsNewReads() {
        let cache = makeCache()
        XCTAssertTrue(cache.prepareSync())
        cache.cancel()
        XCTAssertThrowsError(
            try cache.readSync(range: KSPlayerMediaCacheRange(start: 0, end: 32 * 1024))
        )
    }

    func testCancellationStopsBlockedProbe() {
        let requestStarted = KSPlayerPlaybackRangeFixtureURLProtocol.lock.withLock {
            KSPlayerPlaybackRangeFixtureURLProtocol.stallsRequests = true
            return KSPlayerPlaybackRangeFixtureURLProtocol.requestStarted
        }
        let preparation = KSPlayerPlaybackRangePreparationState()
        let cache = makeCache()
        defer { cache.cancel() }

        DispatchQueue.global(qos: .utility).async {
            preparation.finish(cache.prepareSync())
        }
        guard requestStarted.wait(timeout: .now() + 1) == .success else {
            XCTFail("The blocking fixture request did not start.")
            return
        }

        cache.cancel()
        XCTAssertEqual(preparation.completed.wait(timeout: .now() + 1), .success)
        XCTAssertEqual(preparation.takeResult(), false)
    }

    func testPlaybackRangeCacheIsExplicitlyDisabledByDefault() {
        let options = KSOptions()
        XCTAssertFalse(options.playbackRangeCacheEnabled)
        XCTAssertEqual(options.playbackRangeCacheBlockSize, blockSize)
        XCTAssertEqual(options.playbackRangeCacheCapacity, capacity)
    }

    private func makeCache(
        blockSize: Int64? = nil,
        capacity: Int64? = nil,
        shouldCancel: @escaping @Sendable () -> Bool = { false }
    ) -> KSPlayerPlaybackRangeCache {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [KSPlayerPlaybackRangeFixtureURLProtocol.self]
        return KSPlayerPlaybackRangeCache(
            url: URL(string: "https://fixture.invalid/video.mp4")!,
            headers: ["Cookie": "fixture=1"],
            blockSize: blockSize ?? self.blockSize,
            capacity: capacity ?? self.capacity,
            shouldCancel: shouldCancel,
            session: URLSession(configuration: configuration)
        )
    }
}
