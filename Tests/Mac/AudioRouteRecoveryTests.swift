import XCTest
import AVFoundation

final class AudioRouteRecoveryTests: XCTestCase {
    func testAudioPeakMeterHandlesInt16Min() {
        let samples: [Int16] = [0, 1, -1, Int16.max, Int16.min]
        let peak = AudioPeakMeter.normalizedPeak(samples: samples)
        XCTAssertEqual(peak, 1.0, accuracy: 0.0001)
    }

    func testAudioRouteRecoveryPolicy() {
        XCTAssertTrue(AudioRouteRecoveryPolicy.shouldCancelActiveCapture(isRecording: true))
        XCTAssertFalse(AudioRouteRecoveryPolicy.shouldCancelActiveCapture(isRecording: false))
        XCTAssertTrue(AudioRouteRecoveryPolicy.shouldRejectStart(isRecovering: true, isInputReady: true))
        XCTAssertTrue(AudioRouteRecoveryPolicy.shouldRejectStart(isRecovering: false, isInputReady: false))
        XCTAssertFalse(AudioRouteRecoveryPolicy.shouldRejectStart(isRecovering: false, isInputReady: true))
        XCTAssertTrue(AudioRouteRecoveryPolicy.canRetry(attempt: 2, maxAttempts: 3))
        XCTAssertFalse(AudioRouteRecoveryPolicy.canRetry(attempt: 3, maxAttempts: 3))
    }

    func testAudioCaptureSinkRebuildsConverterAcrossFormats() throws {
        let target = try XCTUnwrap(
            AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: true)
        )
        let sink = AudioCaptureSink()
        sink.configure(targetFormat: target)
        sink.beginRecording()

        let format48 = try XCTUnwrap(
            AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 1, interleaved: false)
        )
        let buffer48 = try XCTUnwrap(makeSineBuffer(format: format48, frames: 4800, frequency: 440))
        sink.ingest(buffer48)
        let after48 = sink.snapshot()
        XCTAssertFalse(after48.isEmpty)

        let format16 = try XCTUnwrap(
            AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: true)
        )
        let buffer16 = try XCTUnwrap(makeSineBuffer(format: format16, frames: 1600, frequency: 440))
        sink.prepareForEngineAttach()
        sink.ingest(buffer16)
        let after16 = sink.snapshot()
        XCTAssertGreaterThan(after16.count, after48.count)

        if let channel = buffer16.int16ChannelData {
            channel[0][0] = Int16.min
        }
        sink.ingest(buffer16)
        XCTAssertGreaterThanOrEqual(sink.latestLevel, 0)
        XCTAssertLessThanOrEqual(sink.latestLevel, 1.0)

        let finished = sink.finishRecording()
        XCTAssertFalse(finished.isEmpty)
        XCTAssertEqual(finished.count % 2, 0)
    }

    private func makeSineBuffer(format: AVAudioFormat, frames: AVAudioFrameCount, frequency: Double) -> AVAudioPCMBuffer? {
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return nil }
        buffer.frameLength = frames
        let sampleRate = format.sampleRate
        if format.commonFormat == .pcmFormatFloat32, let channels = buffer.floatChannelData {
            let ptr = channels[0]
            for i in 0..<Int(frames) {
                let t = Double(i) / sampleRate
                ptr[i] = Float(sin(2 * Double.pi * frequency * t) * 0.25)
            }
        } else if format.commonFormat == .pcmFormatInt16, let channels = buffer.int16ChannelData {
            let ptr = channels[0]
            for i in 0..<Int(frames) {
                let t = Double(i) / sampleRate
                let sample = sin(2 * Double.pi * frequency * t) * 0.25 * Double(Int16.max)
                ptr[i] = Int16(clamping: Int(sample.rounded()))
            }
        } else {
            return nil
        }
        return buffer
    }
}
