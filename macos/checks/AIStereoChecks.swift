import Foundation
import CoreVideo
import Metal
import CoreImage

@main
struct AIStereoChecks {
    static func buffer(_ width: Int, _ height: Int, _ format: OSType) -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        precondition(CVPixelBufferCreate(kCFAllocatorDefault, width, height, format,
            [kCVPixelBufferMetalCompatibilityKey: true, kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &buffer) == 0)
        return buffer!
    }
    static func bytes(_ buffer: CVPixelBuffer) -> [UInt8] {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        return Array(UnsafeBufferPointer(start: CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self),
                                        count: CVPixelBufferGetBytesPerRow(buffer) * CVPixelBufferGetHeight(buffer)))
    }
    static func main() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { fatalError("Metal unavailable") }
        let frame = buffer(320, 180, kCVPixelFormatType_32BGRA)
        CVPixelBufferLockBaseAddress(frame, [])
        for y in 0..<180 {
            let row = CVPixelBufferGetBaseAddress(frame)!.advanced(by: y * CVPixelBufferGetBytesPerRow(frame)).assumingMemoryBound(to: UInt8.self)
            for x in 0..<320 { row[x * 4] = 40; row[x * 4 + 1] = UInt8(y); row[x * 4 + 2] = UInt8(x * 255 / 319); row[x * 4 + 3] = 255 }
        }
        CVPixelBufferUnlockBaseAddress(frame, [])
        let original = bytes(frame)
        let depth = buffer(320, 180, kCVPixelFormatType_OneComponent32Float)
        CVPixelBufferLockBaseAddress(depth, [])
        for y in 0..<180 {
            let row = CVPixelBufferGetBaseAddress(depth)!.advanced(by: y * CVPixelBufferGetBytesPerRow(depth)).assumingMemoryBound(to: Float.self)
            for x in 0..<320 { row[x] = y < 90 ? 1 : 0 }
        }
        CVPixelBufferUnlockBaseAddress(depth, [])
        let renderer = try StereoMetalRenderer(device: device)
        func render(width: Int, height: Int, video: CVPixelBuffer? = nil, map: CVPixelBuffer? = nil) throws -> [UInt8] {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
            descriptor.usage = [.renderTarget, .shaderRead]; descriptor.storageMode = .shared
            let output = device.makeTexture(descriptor: descriptor)!
            let command = try renderer.render(frame: video ?? frame, depth: map ?? depth, into: output)
            command.waitUntilCompleted()
            precondition(command.status == .completed, command.error?.localizedDescription ?? "GPU failed")
            var pixels = [UInt8](repeating: 0, count: width * height * 4)
            output.getBytes(&pixels, bytesPerRow: width * 4, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
            return pixels
        }
        let pixels = try render(width: 640, height: 180)
        func red(_ x: Int, _ y: Int) -> Int { Int(pixels[(y * 640 + x) * 4 + 2]) }
        precondition(red(160, 45) < red(480, 45), "Near depth must shift opposite ways in the two eyes")
        precondition(red(160, 135) > red(480, 135), "Far depth must reverse disparity")
        precondition(pixels[(45 * 640 + 160) * 4 + 1] < pixels[(135 * 640 + 160) * 4 + 1], "Video must stay upright")
        renderer.depthStrength = .gentle
        let gentle = try render(width: 640, height: 180)
        renderer.depthStrength = .strong
        let strong = try render(width: 640, height: 180)
        let left = (45 * 640 + 160) * 4 + 2, right = (45 * 640 + 480) * 4 + 2
        precondition(Int(strong[right]) - Int(strong[left]) > Int(gentle[right]) - Int(gentle[left]), "Strong must increase stereo separation")
        renderer.depthStrength = .balanced
        let boxed = try render(width: 640, height: 360)
        precondition(boxed[2] == 0 && boxed[(320 * 4) + 2] == 0, "Letterbox each eye separately")
        CVPixelBufferLockBaseAddress(depth, [])
        for y in 0..<180 {
            let row = CVPixelBufferGetBaseAddress(depth)!.advanced(by: y * CVPixelBufferGetBytesPerRow(depth)).assumingMemoryBound(to: Float.self)
            for x in 0..<320 { row[x] = .nan }
        }
        CVPixelBufferUnlockBaseAddress(depth, [])
        let neutral = try render(width: 640, height: 180)
        precondition(neutral[(45 * 640 + 160) * 4 + 2] == neutral[(45 * 640 + 480) * 4 + 2], "Invalid depth must give neutral disparity")
        precondition(bytes(frame) == original, "Rendering must never modify the decoded source frame")
        print("Stereo GPU checks passed: opposite near/far disparity, upright image, letterboxing, invalid depth fallback, unchanged source.")

        let silhouette = buffer(320, 180, kCVPixelFormatType_32BGRA)
        let silhouetteDepth = buffer(320, 180, kCVPixelFormatType_OneComponent32Float)
        renderer.depthStrength = .strong
        for start in [140, 150, 160, 150, 140] {
            CVPixelBufferLockBaseAddress(silhouette, [])
            CVPixelBufferLockBaseAddress(silhouetteDepth, [])
            for y in 0..<180 {
                let rgb = CVPixelBufferGetBaseAddress(silhouette)!.advanced(by: y * CVPixelBufferGetBytesPerRow(silhouette)).assumingMemoryBound(to: UInt8.self)
                let z = CVPixelBufferGetBaseAddress(silhouetteDepth)!.advanced(by: y * CVPixelBufferGetBytesPerRow(silhouetteDepth)).assumingMemoryBound(to: Float.self)
                for x in 0..<320 {
                    let foreground = x >= start && x < start + 40 && y >= 30 && y < 150
                    rgb[x * 4] = foreground ? 0 : (x % 6 < 3 ? 96 : 255); rgb[x * 4 + 1] = 0
                    rgb[x * 4 + 2] = foreground ? 255 : 0; rgb[x * 4 + 3] = 255
                    z[x] = foreground ? 0.95 : 0.05
                }
            }
            CVPixelBufferUnlockBaseAddress(silhouette, [])
            CVPixelBufferUnlockBaseAddress(silhouetteDepth, [])
            let source = bytes(silhouette)
            let views = try render(width: 640, height: 180, video: silhouette, map: silhouetteDepth)
            for eye in 0..<2 {
                var runs = 0, count = 0, wasRed = false, first = -1
                for x in 0..<320 {
                    let offset = (90 * 640 + eye * 320 + x) * 4
                    let red = views[offset + 2] > 128
                    precondition(!(views[offset] > 4 && views[offset + 2] > 4), "Outlines must not blend foreground and background colors into a blurry rim")
                    if red { count += 1; if !wasRed { runs += 1; if first < 0 { first = x } } }
                    wasRed = red
                }
                precondition(runs == 1, "Moving foreground must appear once per eye, without a second outline")
                precondition(abs(count - 40) <= 2, "Occlusion handling must preserve the character's width")
                precondition(abs(first - (start + (eye == 0 ? 7 : -7))) <= 1, "Foreground must move to the correct eye position")
            }
            let exposedBackground = (start - 6..<start + 6).map { views[(90 * 640 + $0) * 4] }
            precondition(Set(exposedBackground).count > 1, "Exposed background must keep texture instead of stretching a single border pixel")
            precondition(bytes(silhouette) == source)
        }
        renderer.depthStrength = .balanced
        print("Occlusion regression passed: one moving silhouette per eye, sharp outlines, textured background fill, correct depth order and preserved width.")

        func fillDepth(near: Float, far: Float) {
            CVPixelBufferLockBaseAddress(depth, [])
            for y in 0..<180 {
                let row = CVPixelBufferGetBaseAddress(depth)!.advanced(by: y * CVPixelBufferGetBytesPerRow(depth)).assumingMemoryBound(to: Float.self)
                for x in 0..<320 { row[x] = y < 90 ? near : far }
            }
            CVPixelBufferUnlockBaseAddress(depth, [])
        }
        func value(_ buffer: CVPixelBuffer, x: Int = 160, y: Int = 45) -> Float {
            CVPixelBufferLockBaseAddress(buffer, .readOnly)
            defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
            return CVPixelBufferGetBaseAddress(buffer)!.advanced(by: y * CVPixelBufferGetBytesPerRow(buffer)).assumingMemoryBound(to: Float.self)[x]
        }
        let stabilization = StereoDepthStabilizer()
        fillDepth(near: 0.55, far: 0.45)
        let first = try stabilization.process(depth, image: frame, time: 1)
        precondition(value(first) - value(first, y: 135) > 0.25, "Compressed depth must gain usable contrast")
        fillDepth(near: 0.56, far: 0.44)
        let raw = try StereoDepthStabilizer().process(depth, image: frame, time: 1)
        let smooth = try stabilization.process(depth, image: frame, time: 1.04)
        precondition(abs(value(smooth) - value(first)) < abs(value(raw) - value(first)) * 0.5, "Static depth jitter must be reduced")
        precondition(abs(value(smooth, y: 89) - value(raw, y: 89)) < 0.001, "Depth boundaries must not blend old silhouettes")
        let changed = buffer(320, 180, kCVPixelFormatType_32BGRA)
        CVPixelBufferLockBaseAddress(changed, [])
        original.withUnsafeBytes { source in
            for y in 0..<180 {
                memcpy(CVPixelBufferGetBaseAddress(changed)!.advanced(by: y * CVPixelBufferGetBytesPerRow(changed)),
                       source.baseAddress!.advanced(by: y * CVPixelBufferGetBytesPerRow(frame)), 320 * 4)
            }
        }
        let subtlePixel = CVPixelBufferGetBaseAddress(changed)!.advanced(by: 45 * CVPixelBufferGetBytesPerRow(changed)).assumingMemoryBound(to: UInt8.self).advanced(by: 160 * 4)
        subtlePixel[2] += 25
        CVPixelBufferUnlockBaseAddress(changed, [])
        let subtleMotion = try stabilization.process(depth, image: changed, time: 1.05)
        precondition(abs(value(subtleMotion) - value(raw)) < 0.001, "Low-contrast movement must reject previous depth")
        CVPixelBufferLockBaseAddress(changed, [])
        CVPixelBufferGetBaseAddress(changed)!.advanced(by: 45 * CVPixelBufferGetBytesPerRow(changed)).assumingMemoryBound(to: UInt32.self)[160] = .max
        CVPixelBufferUnlockBaseAddress(changed, [])
        let moving = try stabilization.process(depth, image: changed, time: 1.06)
        precondition(abs(value(moving) - value(raw)) < 0.001, "Moving pixels must reject old depth to avoid trails")
        CVPixelBufferLockBaseAddress(changed, [])
        memset(CVPixelBufferGetBaseAddress(changed), 255, CVPixelBufferGetBytesPerRow(changed) * 180)
        CVPixelBufferUnlockBaseAddress(changed, [])
        fillDepth(near: 0.9, far: 0.8)
        let cut = try stabilization.process(depth, image: changed, time: 1.08)
        let fresh = try StereoDepthStabilizer().process(depth, image: changed, time: 1.08)
        precondition(abs(value(cut) - value(fresh)) < 0.001, "Scene cuts must reset old depth")
        fillDepth(near: 0.55, far: 0.45)
        let gap = try stabilization.process(depth, image: changed, time: 3)
        precondition(abs(value(gap) - value(first)) < 0.001, "Long gaps and seeking must reset history")
        fillDepth(near: 0.8, far: 0.8)
        let flat = try StereoDepthStabilizer().process(depth, image: frame, time: 1)
        precondition(abs(value(flat) - 0.5) < 0.01, "Flat depth must stay neutral instead of amplifying noise")
        precondition(bytes(frame) == original)
        print("Depth enhancement checks passed: stronger stereo, contrast, jitter reduction, cut/gap reset, flat-scene stability.")

        let processor = try StereoDepthProcessor(modelURL: URL(fileURLWithPath: CommandLine.arguments[1]), device: device)
        var timings: [Double] = []
        for index in 0..<12 {
            let start = CFAbsoluteTimeGetCurrent()
            let estimate = try processor.depth(for: frame)
            let ms = (CFAbsoluteTimeGetCurrent() - start) * 1000
            precondition(CVPixelBufferGetWidth(estimate) == 518 && CVPixelBufferGetHeight(estimate) == 392)
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: 3840, height: 1080, mipmapped: false)
            descriptor.usage = [.renderTarget]; descriptor.storageMode = .private
            let command = try renderer.render(frame: frame, depth: estimate, into: device.makeTexture(descriptor: descriptor)!)
            command.waitUntilCompleted()
            precondition(command.status == .completed)
            if index > 0 { timings.append(ms) }
        }
        let fullHD = buffer(1920, 1080, kCVPixelFormatType_32BGRA)
        CIContext(mtlDevice: device).render(CIImage(cvPixelBuffer: frame).transformed(by: CGAffineTransform(scaleX: 6, y: 6)), to: fullHD)
        let hdDepth = try processor.depth(for: fullHD)
        let fullOutput = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: 3840, height: 1080, mipmapped: false)
        fullOutput.usage = [.renderTarget]; fullOutput.storageMode = .private
        let hdTexture = device.makeTexture(descriptor: fullOutput)!
        var renderTimes: [Double] = []
        for _ in 0..<4 {
            let start = CFAbsoluteTimeGetCurrent()
            let command = try renderer.render(frame: fullHD, depth: hdDepth, into: hdTexture)
            command.waitUntilCompleted()
            precondition(command.status == .completed)
            renderTimes.append((CFAbsoluteTimeGetCurrent() - start) * 1000)
        }
        print(String(format: "Full-HD projection and 3840×1080 output: %.1f ms warm average.", renderTimes.dropFirst().reduce(0, +) / 3))
        precondition(bytes(frame) == original, "Inference must not mutate the source")
        var delivered = 0
        for _ in 0..<100 {
            processor.submit(frame) { result in
                guard case .success = result else { fatalError("Inference failed") }
                delivered += 1
            }
        }
        let deadline = Date().addingTimeInterval(5)
        while delivered == 0 && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
        precondition(delivered == 1, "The inference queue must be bounded to one frame")
        processor.submit(frame) { _ in delivered += 1 }
        processor.cancel()
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        precondition(delivered == 1, "Cancelled sessions must not deliver stale results")
        print(String(format: "Core ML checks passed: real depth output, Full-SBS render, bounded queue, cancellation. Warm average %.1f ms.", timings.reduce(0, +) / Double(timings.count)))
    }
}
