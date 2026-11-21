import Foundation
import CoreML
import CoreImage
import MetalKit
import Darwin

// A separate process bounds model memory and makes cancellation independent of inference.
@main
struct DepthPreparationWorker {
    static var children: [Process] = []
    static let childLock = NSLock()
    static var cancellation: DispatchSourceSignal?
    static var log: FileHandle!
    static var workingDirectory: URL?

    static func progress(_ fraction: Double, _ message: String) {
        if let data = try? JSONSerialization.data(withJSONObject: ["progress": fraction, "message": message]) {
            FileHandle.standardOutput.write(data + Data([10]))
        }
    }
    static func launch(_ executable: URL, _ arguments: [String], input: Any? = nil, output: Any? = nil) throws -> Process {
        let process = Process()
        process.executableURL = executable; process.arguments = arguments
        process.standardInput = input ?? FileHandle.nullDevice
        process.standardOutput = output ?? FileHandle.nullDevice
        process.standardError = log
        childLock.lock(); children.append(process); childLock.unlock()
        try process.run()
        return process
    }
    static func finish(_ process: Process) throws {
        process.waitUntilExit()
        childLock.lock(); children.removeAll { $0 === process }; childLock.unlock()
        guard process.terminationStatus == 0 else { throw StereoError("Media processing failed; see preparation.log in the cache folder") }
    }
    static func readFrame(_ handle: FileHandle, bytes: Int) throws -> Data? {
        var result = Data()
        while result.count < bytes {
            guard let part = try handle.read(upToCount: bytes - result.count), !part.isEmpty else {
                if result.isEmpty { return nil }
                throw StereoError("The video decoder returned an incomplete frame")
            }
            result.append(part)
        }
        return result
    }
    static func pixelBuffer(_ data: Data, width: Int, height: Int, format: OSType) throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        guard CVPixelBufferCreate(kCFAllocatorDefault, width, height, format,
            [kCVPixelBufferMetalCompatibilityKey: true, kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &buffer) == 0,
              let buffer else { throw StereoError("Couldn’t allocate a preparation frame") }
        let bytesPerPixel = 4
        guard data.count == width * height * bytesPerPixel else { throw StereoError("Invalid preparation frame size") }
        CVPixelBufferLockBaseAddress(buffer, [])
        data.withUnsafeBytes { source in
            for y in 0..<height {
                memcpy(CVPixelBufferGetBaseAddress(buffer)!.advanced(by: y * CVPixelBufferGetBytesPerRow(buffer)),
                       source.baseAddress!.advanced(by: y * width * bytesPerPixel), width * bytesPerPixel)
            }
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        return buffer
    }

    struct Probe {
        let fps: Double
        let duration: Double
        let width: Int
        let height: Int
        init(source: URL, ffprobe: URL) throws {
            let pipe = Pipe()
            let process = try launch(ffprobe, ["-v", "error", "-select_streams", "v:0", "-show_entries",
                "stream=width,height,avg_frame_rate,sample_aspect_ratio:stream_tags=rotate:stream_side_data=rotation:format=duration", "-of", "json", source.path], output: pipe)
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            try finish(process)
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let stream = (json["streams"] as? [[String: Any]])?.first,
                  let w = stream["width"] as? Int, let h = stream["height"] as? Int,
                  w > 0, h > 0, w <= 16384, h <= 16384 else { throw StereoError("Couldn’t read this video's dimensions") }
            let rate = (stream["avg_frame_rate"] as? String ?? "").split(separator: "/").compactMap { Double($0) }
            guard rate.count == 2, rate[1] > 0, (rate[0] / rate[1]).isFinite,
                  rate[0] / rate[1] > 0, rate[0] / rate[1] <= 240 else { throw StereoError("Unsupported video frame rate") }
            fps = rate[0] / rate[1]
            duration = Double((json["format"] as? [String: Any])?["duration"] as? String ?? "0") ?? 0
            let sar = (stream["sample_aspect_ratio"] as? String ?? "1:1").split(separator: ":").compactMap { Double($0) }
            var displayWidth = Double(w), displayHeight = Double(h)
            if sar.count == 2, sar[0] > 0, sar[1] > 0 { displayWidth *= sar[0] / sar[1] }
            let rotation = ((stream["side_data_list"] as? [[String: Any]])?.first?["rotation"] as? Int)
                ?? Int((stream["tags"] as? [String: String])?["rotate"] ?? "0") ?? 0
            if rotation % 180 == 90 || rotation % 180 == -90 { swap(&displayWidth, &displayHeight) }
            guard displayWidth.isFinite, displayHeight.isFinite, displayWidth > 0, displayHeight > 0 else { throw StereoError("Invalid video pixel aspect ratio") }
            let scale = min(1, min(1920 / displayWidth, 1080 / displayHeight))
            width = max(2, Int(displayWidth * scale) / 2 * 2)
            height = max(2, Int(displayHeight * scale) / 2 * 2)
        }
        var rate: String { String(format: "%.9f", locale: Locale(identifier: "en_US_POSIX"), fps) }
        // Bake a 16:9 canvas for each lens, including pillarboxes for 4:3 sources.
        var eyeHeight: Int { min(1080, ((max(height, (width * 9 + 15) / 16) + 17) / 18) * 18) }
        var eyeWidth: Int { eyeHeight * 16 / 9 }
        var crop: (x: Int, y: Int, w: Int, h: Int) {
            let scale = min(700 / Double(width), 392 / Double(height))
            let w = max(2, Int(Double(width) * scale) / 2 * 2)
            let h = max(2, Int(Double(height) * scale) / 2 * 2)
            return ((700 - w) / 2, (392 - h) / 2, w, h)
        }
    }

    static func decoder(source: URL, ffmpeg: URL, probe: Probe, small: Bool) throws -> (Process, FileHandle) {
        let pipe = Pipe()
        let crop = probe.crop
        let scale = small ? "scale=\(crop.w):\(crop.h),format=bgra,pad=700:392:\(crop.x):\(crop.y)" : "scale=\(probe.width):\(probe.height)"
        let process = try launch(ffmpeg, ["-hide_banner", "-loglevel", "error", "-nostdin", "-i", source.path,
            "-map", "0:v:0", "-an", "-sn", "-vf", "fps=\(probe.rate),\(scale),setsar=1", "-pix_fmt", "bgra", "-f", "rawvideo", "pipe:1"], output: pipe)
        try pipe.fileHandleForWriting.close()
        return (process, pipe.fileHandleForReading)
    }

    static func createDepth(cache: PreparedDepthCache, source: URL, ffmpeg: URL, modelURL: URL, probe: Probe) throws -> PreparedDepthManifest {
        progress(0, "Loading the temporal video-depth model…")
        let configuration = MLModelConfiguration(); configuration.computeUnits = .cpuAndGPU
        let model = try MLModel(contentsOf: modelURL, configuration: configuration)
        progress(0, "Estimating temporal depth: first 32-frame window…")
        let input = try MLMultiArray(shape: [1, 32, 3, 392, 700], dataType: .float32)
        let features = try MLDictionaryFeatureProvider(dictionary: ["frames": MLFeatureValue(multiArray: input)])
        let (decode, reader) = try decoder(source: source, ffmpeg: ffmpeg, probe: probe, small: true)
        let temporary = cache.directory.appendingPathComponent("depth.partial.mkv")
        let pipe = Pipe()
        let encode = try launch(ffmpeg, ["-hide_banner", "-loglevel", "error", "-nostdin", "-y", "-f", "rawvideo", "-pix_fmt", "gray16le",
            "-video_size", "700x392", "-framerate", probe.rate, "-i", "pipe:0", "-an", "-c:v", "ffv1", "-level", "3", temporary.path], input: pipe)
        try pipe.fileHandleForReading.close()
        let writer = pipe.fileHandleForWriting
        var histogram = [Int](repeating: 0, count: 65536)
        var frameCount = 0
        let crop = probe.crop
        func emit(_ depth: [Float]) throws {
            var bits = [UInt16](repeating: 0, count: depth.count)
            for index in depth.indices {
                let value = depth[index].isFinite ? min(65000, max(0, depth[index])) : 0
                bits[index] = Float16(value).bitPattern.littleEndian
                let x = index % 700, y = index / 700
                if index % 16 == 0, x >= crop.x, x < crop.x + crop.w, y >= crop.y, y < crop.y + crop.h {
                    histogram[Int(Float16(value).bitPattern)] += 1
                }
            }
            try bits.withUnsafeBytes { try writer.write(contentsOf: Data($0)) }
            frameCount += 1
        }
        func predict(_ frames: [Data]) throws -> [[Float]] {
            try cache.checkUnchanged()
            guard frames.count == 32 else { throw StereoError("Invalid temporal window") }
            let values = input.dataPointer.assumingMemoryBound(to: Float.self)
            let pixels = 700 * 392
            for frame in 0..<32 {
                frames[frame].withUnsafeBytes { bytes in
                    let rgb = bytes.bindMemory(to: UInt8.self)
                    for index in 0..<pixels {
                        values[(frame * 3) * pixels + index] = (Float(rgb[index * 4 + 2]) / 255 - 0.485) / 0.229
                        values[(frame * 3 + 1) * pixels + index] = (Float(rgb[index * 4 + 1]) / 255 - 0.456) / 0.224
                        values[(frame * 3 + 2) * pixels + index] = (Float(rgb[index * 4]) / 255 - 0.406) / 0.225
                    }
                }
            }
            return try autoreleasepool {
                guard let output = try model.prediction(from: features).featureValue(for: "depth")?.multiArrayValue,
                      output.shape.map(\.intValue) == [1, 32, 392, 700], output.dataType == .float32 else {
                    throw StereoError("Unexpected video-depth model output")
                }
                let pointer = output.dataPointer.assumingMemoryBound(to: Float.self)
                let stride = output.strides.map(\.intValue)
                return (0..<32).map { frame in
                    var result = [Float](repeating: 0, count: pixels)
                    for y in 0..<392 { for x in 0..<700 { result[y * 700 + x] = pointer[frame * stride[1] + y * stride[2] + x * stride[3]] } }
                    return result
                }
            }
        }
        var first: [Data] = []
        while first.count < 32, let frame = try readFrame(reader, bytes: 700 * 392 * 4) { first.append(frame) }
        guard let last = first.last else { throw StereoError("This video has no decodable frames") }
        let initialCount = first.count
        while first.count < 32 { first.append(last) }
        var depths = try predict(first)
        if initialCount < 32 {
            for index in 0..<initialCount { try emit(depths[index]) }
        } else {
            // Official long-video schedule: 2 anchors, 8 overlap frames, 22 new frames.
            var anchors = [first[0], first[12]]
            var references = [depths[0], depths[12]]
            var overlapFrames = Array(first.suffix(8))
            var overlapDepths = Array(depths.suffix(8))
            for index in 0..<24 { try emit(depths[index]) }
            while true {
                var next: [Data] = []
                while next.count < 22, let frame = try readFrame(reader, bytes: 700 * 392 * 4) { next.append(frame) }
                guard let last = next.last else { break }
                let count = next.count
                while next.count < 22 { next.append(last) }
                let window = anchors + overlapFrames + next
                depths = try predict(window)
                var n: Double = 0, sumX: Double = 0, sumY: Double = 0, sumXX: Double = 0, sumXY: Double = 0
                for anchor in 0..<2 { for index in stride(from: 0, to: 700 * 392, by: 16) {
                    let x = Double(depths[anchor][index]), y = Double(references[anchor][index])
                    if x.isFinite, y.isFinite { n += 1; sumX += x; sumY += y; sumXX += x * x; sumXY += x * y }
                } }
                let denominator = n * sumXX - sumX * sumX
                var scale = denominator > 1e-8 ? (n * sumXY - sumX * sumY) / denominator : 1
                if !scale.isFinite || scale <= 0 { scale = 1 }
                let shift = n > 0 ? (sumY - scale * sumX) / n : 0
                for frame in 0..<32 { for index in depths[frame].indices {
                    depths[frame][index] = max(0, Float(Double(depths[frame][index]) * scale + shift))
                } }
                for frame in 0..<8 {
                    let weight = Float(frame) / 7
                    for index in overlapDepths[frame].indices { overlapDepths[frame][index] = overlapDepths[frame][index] * (1 - weight) + depths[frame + 2][index] * weight }
                }
                let pending = overlapDepths + Array(depths[10..<(10 + count)])
                if count < 22 { for depth in pending { try emit(depth) }; overlapDepths = []; break }
                for depth in pending.dropLast(8) { try emit(depth) }
                overlapDepths = Array(pending.suffix(8))
                overlapFrames = Array(window.suffix(8))
                anchors = [anchors[0], window[12]]; references = [references[0], depths[12]]
                progress(min(0.65, Double(frameCount) / max(1, probe.duration * probe.fps) * 0.65), "Preparing temporal depth: \(frameCount) frames")
            }
            for depth in overlapDepths { try emit(depth) }
        }
        try reader.close(); try finish(decode)
        try writer.close(); try finish(encode)
        try cache.checkUnchanged()
        let samples = histogram.reduce(0, +)
        func percentile(_ percent: Double) -> Float {
            var count = 0
            for index in histogram.indices {
                count += histogram[index]
                if count >= max(1, Int(Double(samples) * percent)) { return Float(Float16(bitPattern: UInt16(index))) }
            }
            return 0
        }
        var low = percentile(0.01), high = percentile(0.99)
        if high - low < 0.001 { low -= 0.0005; high = low + 0.001 }
        let manifest = PreparedDepthManifest(model: PreparedDepthCache.model, source: cache.identity, fps: probe.fps, frames: frameCount,
            width: 700, height: 392, cropX: crop.x, cropY: crop.y, cropWidth: crop.w, cropHeight: crop.h, low: low, high: high)
        try? FileManager.default.removeItem(at: cache.depthURL)
        try FileManager.default.moveItem(at: temporary, to: cache.depthURL)
        try cache.publish(manifest)
        return manifest
    }

    static func render(cache: PreparedDepthCache, source: URL, ffmpeg: URL, probe: Probe, manifest: PreparedDepthManifest) throws {
        progress(0.65, "Rendering the prepared Full-SBS video…")
        guard let device = MTLCreateSystemDefaultDevice() else { throw StereoError("Metal is unavailable") }
        let renderer = try StereoMetalRenderer(device: device); renderer.depthStrength = cache.strength
        let (decode, videoReader) = try decoder(source: source, ffmpeg: ffmpeg, probe: probe, small: false)
        let depthPipe = Pipe()
        let depthDecode = try launch(ffmpeg, ["-hide_banner", "-loglevel", "error", "-nostdin", "-i", cache.depthURL.path,
            "-f", "rawvideo", "-pix_fmt", "gray16le", "pipe:1"], output: depthPipe)
        try depthPipe.fileHandleForWriting.close()
        let temporary = cache.playbackURL.deletingPathExtension().appendingPathExtension("partial.mkv")
        let pipe = Pipe()
        let encode = try launch(ffmpeg, ["-hide_banner", "-loglevel", "error", "-nostdin", "-y", "-f", "rawvideo", "-pix_fmt", "bgra",
            "-video_size", "\(probe.eyeWidth * 2)x\(probe.eyeHeight)", "-framerate", probe.rate, "-i", "pipe:0", "-i", source.path,
            "-map", "0:v:0", "-map", "1:a?", "-map", "1:s?", "-map", "1:t?", "-map_metadata", "1", "-map_chapters", "1",
            "-c:v", "libx264", "-crf", "16", "-preset", "medium", "-pix_fmt", "yuv420p", "-c:a", "copy", "-c:s", "copy", "-c:t", "copy", temporary.path], input: pipe)
        try pipe.fileHandleForReading.close()
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: probe.eyeWidth * 2, height: probe.eyeHeight, mipmapped: false)
        descriptor.usage = [.renderTarget]; descriptor.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: descriptor) else { throw StereoError("Couldn’t allocate Full-SBS output") }
        let depthReader = depthPipe.fileHandleForReading
        for frame in 0..<manifest.frames {
            try autoreleasepool {
                guard let video = try readFrame(videoReader, bytes: probe.width * probe.height * 4),
                      let depth = try readFrame(depthReader, bytes: 700 * 392 * 2) else { throw StereoError("Prepared depth and video lengths differ") }
                let rgb = try pixelBuffer(video, width: probe.width, height: probe.height, format: kCVPixelFormatType_32BGRA)
                var normalized = [Float](repeating: 0.5, count: manifest.cropWidth * manifest.cropHeight)
                depth.withUnsafeBytes { bytes in
                    let bits = bytes.bindMemory(to: UInt16.self)
                    for y in 0..<manifest.cropHeight { for x in 0..<manifest.cropWidth {
                        let value = Float(Float16(bitPattern: UInt16(littleEndian: bits[(y + manifest.cropY) * 700 + x + manifest.cropX])))
                        normalized[y * manifest.cropWidth + x] = value.isFinite ? min(1, max(0, (value - manifest.low) / (manifest.high - manifest.low))) : 0.5
                    } }
                }
                let zData = normalized.withUnsafeBytes { Data($0) }
                let z = try pixelBuffer(zData, width: manifest.cropWidth, height: manifest.cropHeight, format: kCVPixelFormatType_OneComponent32Float)
                let command = try renderer.render(frame: rgb, depth: z, into: texture)
                command.waitUntilCompleted()
                guard command.status == .completed else { throw StereoError("Full-SBS rendering failed") }
                var output = Data(count: probe.eyeWidth * 2 * probe.eyeHeight * 4)
                output.withUnsafeMutableBytes { bytes in texture.getBytes(bytes.baseAddress!, bytesPerRow: probe.eyeWidth * 2 * 4,
                    from: MTLRegionMake2D(0, 0, probe.eyeWidth * 2, probe.eyeHeight), mipmapLevel: 0) }
                try pipe.fileHandleForWriting.write(contentsOf: output)
            }
            if frame % 24 == 0 {
                try cache.checkUnchanged()
                progress(0.65 + Double(frame + 1) / Double(manifest.frames) * 0.34, "Rendering Full-SBS: \(frame + 1)/\(manifest.frames) frames")
            }
        }
        guard try readFrame(videoReader, bytes: probe.width * probe.height * 4) == nil,
              try readFrame(depthReader, bytes: 700 * 392 * 2) == nil else { throw StereoError("The prepared cache frame count is incorrect") }
        try videoReader.close(); try depthReader.close(); try finish(decode); try finish(depthDecode)
        try pipe.fileHandleForWriting.close(); try finish(encode)
        try cache.checkUnchanged()
        try? FileManager.default.removeItem(at: cache.playbackURL)
        try FileManager.default.moveItem(at: temporary, to: cache.playbackURL)
    }

    static func main() {
        do {
            guard CommandLine.arguments.count == 5,
                  let value = Float(CommandLine.arguments[2]), let strength = StereoDepthStrength(rawValue: value) else {
                throw StereoError("Usage: ShoeboxDepth source strength resources cache-root")
            }
            let source = URL(fileURLWithPath: CommandLine.arguments[1])
            let resources = URL(fileURLWithPath: CommandLine.arguments[3])
            let cache = try PreparedDepthCache(source: source, strength: strength, root: URL(fileURLWithPath: CommandLine.arguments[4]))
            try FileManager.default.createDirectory(at: cache.directory, withIntermediateDirectories: true)
            let lockFD = open(cache.directory.appendingPathComponent(".lock").path, O_CREAT | O_RDWR, 0o600)
            guard lockFD >= 0, flock(lockFD, LOCK_EX | LOCK_NB) == 0 else { throw StereoError("This video is already being prepared") }
            workingDirectory = cache.directory
            defer { flock(lockFD, LOCK_UN); close(lockFD) }
            let logURL = cache.directory.appendingPathComponent("preparation.log")
            FileManager.default.createFile(atPath: logURL.path, contents: nil)
            log = try FileHandle(forWritingTo: logURL)
            signal(SIGTERM, SIG_IGN)
            signal(SIGPIPE, SIG_IGN)
            let signalSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .global())
            signalSource.setEventHandler {
                childLock.lock(); let jobs = children; childLock.unlock()
                for process in jobs where process.isRunning { process.terminate() }
                if let files = try? FileManager.default.contentsOfDirectory(at: cache.directory, includingPropertiesForKeys: nil) {
                    for file in files where file.lastPathComponent.hasSuffix(".partial.mkv") { try? FileManager.default.removeItem(at: file) }
                }
                exit(130)
            }
            cancellation = signalSource; signalSource.resume()
            if !cache.ready {
                let ffmpeg = resources.appendingPathComponent("runtime/ffmpeg")
                let probe = try Probe(source: source, ffprobe: resources.appendingPathComponent("runtime/ffprobe"))
                let manifest = try cache.manifest ?? createDepth(cache: cache, source: source, ffmpeg: ffmpeg,
                    modelURL: resources.appendingPathComponent("VideoDepthAnythingSmall32.mlmodelc"), probe: probe)
                try render(cache: cache, source: source, ffmpeg: ffmpeg, probe: probe, manifest: manifest)
            }
            progress(1, "High-quality 3D is ready")
        } catch {
            childLock.lock(); let jobs = children; childLock.unlock()
            for process in jobs where process.isRunning { process.terminate() }
            if let directory = workingDirectory, let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
                for file in files where file.lastPathComponent.hasSuffix(".partial.mkv") { try? FileManager.default.removeItem(at: file) }
            }
            FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8))
            exit(1)
        }
    }
}
