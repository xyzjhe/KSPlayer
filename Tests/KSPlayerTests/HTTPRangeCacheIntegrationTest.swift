import FFmpegKit
import Foundation
@testable import KSPlayer
import Libavcodec
import Libavformat
import Libavutil
import XCTest

final class HTTPRangeCacheIntegrationTest: XCTestCase {
    @MainActor
    func testDemuxCanSeekBackwardAfterDrainingCachedInputToEOF() async throws {
        let url = try await DeterministicMediaFixture.videoURL()
        defer { try? FileManager.default.removeItem(at: url) }
        var source: UnsafeMutablePointer<AVIOContext>?
        var cache: UnsafeMutablePointer<AVIOContext>?
        var format: UnsafeMutablePointer<AVFormatContext>?
        defer {
            avformat_close_input(&format)
            ksplayer_http_range_cache_free(&cache)
            if source != nil { avio_closep(&source) }
        }
        XCTAssertEqual(avio_open2(&source, url.path, AVIO_FLAG_READ, nil, nil), 0)
        let openedSource = try XCTUnwrap(source)
        XCTAssertEqual(ksplayer_http_range_cache_create(&cache, openedSource, nil), 0)
        _ = try XCTUnwrap(cache)
        source = nil // The C wrapper owns the transport after successful creation.
        format = try XCTUnwrap(avformat_alloc_context())
        format?.pointee.pb = cache
        XCTAssertEqual(avformat_open_input(&format, url.path, nil, nil), 0)
        let openedFormat = try XCTUnwrap(format)
        XCTAssertGreaterThanOrEqual(avformat_find_stream_info(openedFormat, nil), 0)
        var packet: UnsafeMutablePointer<AVPacket>? = try XCTUnwrap(av_packet_alloc())
        defer { av_packet_free(&packet) }
        for target: Int64 in [2_000_000, 0, 1_000_000, 0] {
            XCTAssertGreaterThanOrEqual(
                avformat_seek_file(openedFormat, -1, Int64.min, target, Int64.max, AVSEEK_FLAG_BACKWARD), 0
            )
            var count = 0
            var result: Int32 = 0
            while count < 100 {
                result = av_read_frame(openedFormat, packet)
                if result < 0 { break }
                count += 1
                av_packet_unref(packet)
            }
            XCTAssertGreaterThan(count, 0)
            XCTAssertEqual(result, KSPlayer.AVError.eof.code)
            XCTAssertLessThanOrEqual(ksplayer_http_range_cache_bytes(cache), 4 * 1024 * 1024)
        }
    }
}
