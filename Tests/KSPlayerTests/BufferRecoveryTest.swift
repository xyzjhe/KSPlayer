import AVFoundation
@testable import KSPlayer
import XCTest

final class BufferRecoveryTest: XCTestCase {
    func testFullDecodedQueuesResumeWithoutOneSecondOfPackets() {
        let options = KSOptions()
        options.preferredForwardBufferDuration = 1
        let video = Capacity(mediaType: .video, fps: 30, frameCount: 16, frameMaxCount: 16)
        let audio = Capacity(mediaType: .audio, fps: 44, frameCount: 32, frameMaxCount: 32)
        XCTAssertTrue(options.playable(capacitys: [video, audio], isFirst: false, isSeek: false).isPlayable)
    }

    func testFullVideoDoesNotBypassAnUnreadyAudioTrack() {
        let options = KSOptions()
        options.preferredForwardBufferDuration = 1
        let video = Capacity(mediaType: .video, fps: 30, frameCount: 16, frameMaxCount: 16)
        let audio = Capacity(mediaType: .audio, fps: 44, frameCount: 2, frameMaxCount: 32)
        XCTAssertFalse(options.playable(capacitys: [video, audio], isFirst: false, isSeek: false).isPlayable)
    }

    func testPartialQueueStillRequiresRecoveryDuration() {
        let options = KSOptions()
        options.preferredForwardBufferDuration = 1
        let video = Capacity(mediaType: .video, fps: 30, frameCount: 15, frameMaxCount: 16)
        XCTAssertFalse(options.playable(capacitys: [video], isFirst: false, isSeek: false).isPlayable)
    }

    func testFullSingleFrameQueueStillNeedsTwoRenderableFrames() {
        let options = KSOptions()
        let video = Capacity(mediaType: .video, fps: 30, frameCount: 1, frameMaxCount: 1)
        XCTAssertFalse(options.playable(capacitys: [video], isFirst: false, isSeek: false).isPlayable)
    }

    func testZeroCapacityIsNotTreatedAsFullAndEOFStillDrains() {
        let options = KSOptions()
        options.preferredForwardBufferDuration = 1
        let video = Capacity(mediaType: .video, fps: 30, frameCount: 2, frameMaxCount: 0)
        XCTAssertFalse(options.playable(capacitys: [video], isFirst: false, isSeek: false).isPlayable)
        var eof = video
        eof.frameCount = 0
        eof.isEndOfFile = true
        XCTAssertTrue(options.playable(capacitys: [eof], isFirst: false, isSeek: false).isPlayable)
    }

    private struct Capacity: CapacityProtocol {
        let mediaType: AVMediaType
        let fps: Float
        var frameCount: Int
        let frameMaxCount: Int
        var packetCount = 0
        var isEndOfFile = false
    }
}
