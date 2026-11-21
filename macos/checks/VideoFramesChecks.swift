import AppKit
import VLCKit
import CoreVideo
import Metal

@main
struct VideoFramesChecks {
    @MainActor static func main() throws {
        _ = NSApplication.shared
        let player = VLCMediaPlayer()
        var received = 0
        var badFrame = false
        let processor = try StereoDepthProcessor(modelURL: URL(fileURLWithPath: CommandLine.arguments[2]), device: MTLCreateSystemDefaultDevice()!)
        var converted = 0
        let frames = ShoeboxVideoFrames { frame in
            let width = CVPixelBufferGetWidth(frame), height = CVPixelBufferGetHeight(frame)
            CVPixelBufferLockBaseAddress(frame, .readOnly)
            let pixel = CVPixelBufferGetBaseAddress(frame)!.assumingMemoryBound(to: UInt8.self)
            let valid = width == 640 && height == 360 && pixel[3] == 255
            if !valid { fputs("Bad frame \(width)x\(height), alpha \(pixel[3])\n", stderr) }
            CVPixelBufferUnlockBaseAddress(frame, .readOnly)
            processor.submit(frame) { result in
                if case .success = result { converted += 1 }
            }
            DispatchQueue.main.async { received += 1; if !valid { badFrame = true } }
        }
        func wait(_ condition: () -> Bool, seconds: Double = 5) {
            let end = Date().addingTimeInterval(seconds)
            while !condition() && Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
            if !condition() { fputs("VLC timeout state=\(player.state.rawValue) frames=\(received) converted=\(converted) time=\(player.time.intValue)\n", stderr); fatalError("Timed out waiting for VLC") }
        }
        frames.attach(to: player)
        player.media = VLCMedia(url: URL(fileURLWithPath: CommandLine.arguments[1]))
        player.play()
        wait({ received >= 20 && converted >= 5 }); fputs("capture passed\n", stderr)
        player.pause()
        wait({ !player.isPlaying }); fputs("pause passed\n", stderr)
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        let pausedCount = received
        let pausedTime = player.time.intValue
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        precondition(abs(player.time.intValue - pausedTime) < 100, "Paused playback time must remain still")
        player.play()
        wait({ received > pausedCount + 5 }); fputs("resume passed\n", stderr)
        player.time = VLCTime(int: 4_000)
        wait({ player.time.intValue >= 4_000 }); fputs("seek passed\n", stderr)
        var stopped = false
        ShoeboxStopPlayer(player) { stopped = true }
        wait({ stopped })
        frames.detach(from: player)
        processor.cancel()
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        let stoppedCount = received
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        precondition(!badFrame, "Invalid video frame")
        precondition(received == stoppedCount, "Stopped playback must not deliver new frames")
        // Reattaching must work after teardown, with no stale inference deliveries.
        frames.attach(to: player)
        player.play()
        wait({ received > stoppedCount + 5 })
        stopped = false
        ShoeboxStopPlayer(player) { stopped = true }
        wait({ stopped })
        frames.detach(from: player)
        player.media = nil
        print("VLC AI integration passed: \(received) frames, \(converted) depth results, pause/resume, seek, stop and restart.")
    }
}
