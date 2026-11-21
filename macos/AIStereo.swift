import AppKit
import CoreML
import CoreImage
import MetalKit

enum StereoDepthStrength: Float, CaseIterable {
    case gentle = 0.018, balanced = 0.032, strong = 0.048
    var title: String {
        switch self {
        case .gentle: return "Gentle"
        case .balanced: return "Balanced (Default)"
        case .strong: return "Strong"
        }
    }
}

// Normalize compressed depth ranges without amplifying flat-scene noise. Blend
// only stable pixels; motion, scene cuts and long gaps discard old depth.
final class StereoDepthStabilizer {
    private var previousDepth: [Float] = []
    private var previousColor: [UInt32] = []
    private var center: Float = 0.5
    private var span: Float = 1
    private var lastTime: Double = -.infinity

    private func difference(_ a: UInt32, _ b: UInt32) -> Float {
        let blue = abs(Int(a & 255) - Int(b & 255))
        let green = abs(Int((a >> 8) & 255) - Int((b >> 8) & 255))
        let red = abs(Int((a >> 16) & 255) - Int((b >> 16) & 255))
        return Float(blue + green + red) / 765
    }

    func process(_ depth: CVPixelBuffer, image: CVPixelBuffer, time: Double = ProcessInfo.processInfo.systemUptime) throws -> CVPixelBuffer {
        let width = CVPixelBufferGetWidth(depth), height = CVPixelBufferGetHeight(depth)
        let format = CVPixelBufferGetPixelFormatType(depth)
        guard width == CVPixelBufferGetWidth(image), height == CVPixelBufferGetHeight(image),
              format == kCVPixelFormatType_OneComponent16Half || format == kCVPixelFormatType_OneComponent32Float else {
            throw StereoError("Unsupported depth stabilization format")
        }
        CVPixelBufferLockBaseAddress(depth, .readOnly)
        CVPixelBufferLockBaseAddress(image, .readOnly)
        defer {
            CVPixelBufferUnlockBaseAddress(depth, .readOnly)
            CVPixelBufferUnlockBaseAddress(image, .readOnly)
        }
        var values = [Float](repeating: .nan, count: width * height)
        var colors = [UInt32](repeating: 0, count: values.count)
        var invalid = [Bool](repeating: false, count: values.count)
        var histogram = [Int](repeating: 0, count: 256)
        var valid = 0
        for y in 0..<height {
            let row = CVPixelBufferGetBaseAddress(depth)!.advanced(by: y * CVPixelBufferGetBytesPerRow(depth))
            let color = CVPixelBufferGetBaseAddress(image)!.advanced(by: y * CVPixelBufferGetBytesPerRow(image)).assumingMemoryBound(to: UInt32.self)
            for x in 0..<width {
                let index = y * width + x
                colors[index] = color[x]
                let value = format == kCVPixelFormatType_OneComponent16Half
                    ? Float(row.assumingMemoryBound(to: Float16.self)[x]) : row.assumingMemoryBound(to: Float.self)[x]
                if value.isFinite {
                    values[index] = min(1, max(0, value))
                    histogram[Int(values[index] * 255)] += 1
                    valid += 1
                } else { invalid[index] = true }
            }
        }
        func percentile(_ fraction: Float) -> Float {
            let target = max(1, Int(Float(valid) * fraction))
            var count = 0
            for index in histogram.indices {
                count += histogram[index]
                if count >= target { return Float(index) / 255 }
            }
            return 0.5
        }
        let low = percentile(0.02), high = percentile(0.98)
        var reset = previousDepth.count != values.count || time - lastTime > 0.5 || time <= lastTime
        if !reset {
            var change: Float = 0
            var samples = 0
            for index in stride(from: 0, to: colors.count, by: 37) {
                change += difference(colors[index], previousColor[index]); samples += 1
            }
            reset = change / Float(max(1, samples)) > 0.14
        }
        let newCenter = (low + high) / 2, newSpan = max(0.35, high - low)
        center = reset ? newCenter : center * 0.8 + newCenter * 0.2
        span = reset ? newSpan : span * 0.8 + newSpan * 0.2
        for index in values.indices {
            values[index] = values[index].isFinite ? min(1, max(0, 0.5 + (values[index] - center) / span)) : 0.5
        }
        if !reset {
            let current = values
            func edge(_ map: [Float], _ x: Int, _ y: Int) -> Bool {
                let index = y * width + x
                return abs(map[index] - map[y * width + max(0, x - 1)]) > 0.05
                    || abs(map[index] - map[y * width + min(width - 1, x + 1)]) > 0.05
                    || abs(map[index] - map[max(0, y - 1) * width + x]) > 0.05
                    || abs(map[index] - map[min(height - 1, y + 1) * width + x]) > 0.05
            }
            for y in 0..<height {
                for x in 0..<width {
                    let index = y * width + x
                    if !invalid[index], difference(colors[index], previousColor[index]) < 0.025,
                       abs(current[index] - previousDepth[index]) < 0.06,
                       !edge(current, x, y), !edge(previousDepth, x, y) {
                        values[index] = previousDepth[index] * 0.55 + current[index] * 0.45
                    }
                }
            }
        }
        var output: CVPixelBuffer?
        guard CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_OneComponent32Float,
            [kCVPixelBufferMetalCompatibilityKey: true, kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &output) == 0,
              let output else { throw StereoError("Couldn’t allocate stabilized depth") }
        CVPixelBufferLockBaseAddress(output, [])
        values.withUnsafeBytes { source in
            for y in 0..<height {
                memcpy(CVPixelBufferGetBaseAddress(output)!.advanced(by: y * CVPixelBufferGetBytesPerRow(output)),
                       source.baseAddress!.advanced(by: y * width * MemoryLayout<Float>.size), width * MemoryLayout<Float>.size)
            }
        }
        CVPixelBufferUnlockBaseAddress(output, [])
        previousDepth = values; previousColor = colors; lastTime = time
        return output
    }
}

// One inference at a time; frames arriving while busy are discarded, never queued.
final class StereoDepthProcessor {
    private let model: MLModel
    private let context: CIContext
    private let input: CVPixelBuffer
    private let stabilizer = StereoDepthStabilizer()
    private let lock = NSLock()
    private var busy = false
    private var active = true
    private let queue = DispatchQueue(label: "Shoebox.depth", qos: .userInitiated)

    init(modelURL: URL, device: MTLDevice) throws {
        let configuration = MLModelConfiguration()
        // Avoid an observed ANE compilation stall; GPU inference also supports both models.
        configuration.computeUnits = .cpuAndGPU
        model = try MLModel(contentsOf: modelURL, configuration: configuration)
        context = CIContext(mtlDevice: device, options: [.cacheIntermediates: false])
        var buffer: CVPixelBuffer?
        let result = CVPixelBufferCreate(kCFAllocatorDefault, 518, 392, kCVPixelFormatType_32BGRA,
                                        [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &buffer)
        guard result == kCVReturnSuccess, let buffer else { throw StereoError("Couldn’t allocate the depth input") }
        input = buffer
    }

    func depth(for frame: CVPixelBuffer) throws -> CVPixelBuffer {
        let image = CIImage(cvPixelBuffer: frame)
        let resized = image.transformed(by: CGAffineTransform(scaleX: 518 / image.extent.width, y: 392 / image.extent.height))
        context.render(resized, to: input)
        let features = try MLDictionaryFeatureProvider(dictionary: ["image": MLFeatureValue(pixelBuffer: input)])
        let prediction = try model.prediction(from: features)
        guard let depth = prediction.featureValue(for: "depth")?.imageBufferValue else {
            throw StereoError("The depth model returned no image")
        }
        return try stabilizer.process(depth, image: input)
    }

    func submit(_ frame: CVPixelBuffer, completion: @escaping (Result<CVPixelBuffer, Error>) -> Void) {
        lock.lock()
        guard active, !busy else { lock.unlock(); return }
        busy = true
        lock.unlock()
        queue.async { [self] in
            let result: Result<CVPixelBuffer, Error> = autoreleasepool { Result { try depth(for: frame) } }
            DispatchQueue.main.async { [self] in
                lock.lock()
                let deliver = active
                busy = false
                lock.unlock()
                if deliver { completion(result) }
            }
        }
    }

    func cancel() { lock.lock(); active = false; lock.unlock() }
}

struct StereoError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

// Project source pixels once per eye, with nearer pixels winning overlaps.
// shortcut: unseen background is approximated from nearby texture; learned background
// reconstruction is needed to recover detail hidden behind foreground objects.
final class StereoMetalRenderer {
    let device: MTLDevice
    var depthStrength: StereoDepthStrength = .balanced
    private let queue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState
    private let projectionPipeline: MTLComputePipelineState
    private let resolvePipeline: MTLComputePipelineState
    private var projection: MTLBuffer?
    private var eyeViews: MTLTexture?
    private var cache: CVMetalTextureCache!
    private static let shader = """
    #include <metal_stdlib>
    using namespace metal;
    struct Vertex { float4 position [[position]]; float2 uv; };
    vertex Vertex stereoVertex(uint i [[vertex_id]]) {
        float2 p = float2((i << 1) & 2, i & 2);
        return {float4(p * float2(2, -2) + float2(-1, 1), 0, 1), p};
    }
    float guidedDepth(texture2d<float> image, texture2d<float> depth, float2 uv) {
        constexpr sampler sample(filter::linear, address::clamp_to_edge);
        float2 size = float2(depth.get_width(), depth.get_height());
        float2 center = floor(uv * size);
        float3 reference = image.sample(sample, uv).rgb;
        float total = 0, weighted = 0;
        for (int y = -1; y <= 1; y++) for (int x = -1; x <= 1; x++) {
            float2 at = (center + float2(x, y) + 0.5f) / size;
            float d = depth.sample(sample, at).r;
            if (!isfinite(d)) continue;
            float3 delta = image.sample(sample, at).rgb - reference;
            float2 spatial = at * size - uv * size;
            float weight = exp(-1.5f * dot(spatial, spatial) - 80.0f * dot(delta, delta));
            weighted += clamp(d, 0.0f, 1.0f) * weight; total += weight;
        }
        return total > 0.00001f ? weighted / total : 0.5f;
    }
    kernel void projectStereo(texture2d<float> image [[texture(0)]], texture2d<float> depth [[texture(1)]],
                              device atomic_uint *map [[buffer(0)]], constant float &strength [[buffer(1)]],
                              uint2 pixel [[thread_position_in_grid]]) {
        uint width = image.get_width(), height = image.get_height();
        if (pixel.x >= width || pixel.y >= height) return;
        float2 uv = (float2(pixel) + 0.5f) / float2(width, height);
        float d = guidedDepth(image, depth, uv);
        uint packed = (uint(round(d * 65535.0f)) << 12) | (pixel.x + 1);
        for (uint eye = 0; eye < 2; eye++) {
            float direction = eye == 0 ? 1.0f : -1.0f;
            int target = int(round(float(pixel.x) + direction * strength * (d - 0.5f) * width));
            if (target >= 0 && target < int(width))
                atomic_fetch_max_explicit(&map[pixel.y * width * 2 + eye * width + uint(target)], packed, memory_order_relaxed);
        }
    }
    float4 projectedColor(uint packed, float target, uint y, uint eye, texture2d<float> image, float strength) {
        constexpr sampler sample(filter::linear, address::clamp_to_edge);
        float width = image.get_width();
        float source = float((packed & 4095) - 1);
        float d = float(packed >> 12) / 65535.0f;
        float direction = eye == 0 ? 1.0f : -1.0f;
        float projected = source + direction * strength * (d - 0.5f) * width;
        float correction = clamp(target - projected, -0.5f, 0.5f);
        uint x = uint(source);
        float3 center = image.read(uint2(x, y)).rgb;
        float3 neighbor = image.read(uint2(correction < 0 ? max(int(x) - 1, 0) : min(x + 1, image.get_width() - 1), y)).rgb;
        float3 contrast = neighbor - center;
        // Keep interpolation inside surfaces; never blend opposite sides of an outline.
        if (dot(contrast, contrast) > 0.01f) return float4(center, 1);
        return float4(image.sample(sample, float2((source + correction + 0.5f) / width,
                                                 (float(y) + 0.5f) / image.get_height())).rgb, 1);
    }
    kernel void resolveStereo(texture2d<float> image [[texture(0)]], texture2d<float, access::write> eyes [[texture(1)]],
                              device const uint *map [[buffer(0)]], constant float &strength [[buffer(1)]],
                              uint2 pixel [[thread_position_in_grid]]) {
        uint width = image.get_width(), height = image.get_height();
        if (pixel.x >= width * 2 || pixel.y >= height) return;
        uint eye = pixel.x / width, x = pixel.x % width;
        uint row = pixel.y * width * 2 + eye * width;
        uint packed = map[row + x];
        if (packed != 0) {
            eyes.write(projectedColor(packed, float(x), pixel.y, eye, image, strength), pixel); return;
        }
        uint left = 0, right = 0;
        int leftX = int(x), rightX = int(x);
        int radius = int(ceil(strength * width)) + 4;
        for (int distance = 1; distance <= radius && (left == 0 || right == 0); distance++) {
            if (left == 0 && int(x) - distance >= 0) { leftX = int(x) - distance; left = map[row + uint(leftX)]; }
            if (right == 0 && x + distance < width) { rightX = int(x) + distance; right = map[row + uint(rightX)]; }
        }
        // Fill from the background side, never blend a character into the gap.
        uint background = left == 0 ? right : right == 0 ? left : (left >> 12) < (right >> 12) ? left : right;
        if (background != 0) {
            int boundary = background == left ? leftX : rightX;
            uint reflectedX = uint(clamp(2 * boundary - int(x), 0, int(width) - 1));
            uint texture = map[row + reflectedX];
            // Continue nearby background texture instead of stretching one border column.
            // Reject samples belonging to a nearer object.
            if (texture != 0 && int(texture >> 12) <= int(background >> 12) + 1311) background = texture;
        }
        float4 color = background != 0 ? float4(image.read(uint2((background & 4095) - 1, pixel.y)).rgb, 1) : float4(0, 0, 0, 1);
        eyes.write(color, pixel);
    }
    fragment float4 stereoFragment(Vertex in [[stage_in]], texture2d<float> eyes [[texture(0)]],
                                   constant float2 &settings [[buffer(0)]]) {
        constexpr sampler sample(filter::linear, address::clamp_to_edge);
        float aspect = float(eyes.get_width()) / 2 / float(eyes.get_height());
        float eyeAspect = settings.x;
        float2 content = float2(min(1.0f, aspect / eyeAspect), min(1.0f, eyeAspect / aspect));
        float2 uv = (float2(fract(in.uv.x * 2), in.uv.y) - 0.5f) / content + 0.5f;
        if (any(uv < 0) || any(uv > 1)) return float4(0, 0, 0, 1);
        float eye = in.uv.x < 0.5f ? 0.0f : 1.0f;
        uv.x = clamp(uv.x, 0.5f / (eyes.get_width() / 2), 1.0f - 0.5f / (eyes.get_width() / 2));
        return eyes.sample(sample, float2((eye + uv.x) * 0.5f, uv.y));
    }
    """

    init(device: MTLDevice) throws {
        self.device = device
        guard let queue = device.makeCommandQueue() else { throw StereoError("Metal is unavailable") }
        self.queue = queue
        let library = try device.makeLibrary(source: Self.shader, options: nil)
        projectionPipeline = try device.makeComputePipelineState(function: library.makeFunction(name: "projectStereo")!)
        resolvePipeline = try device.makeComputePipelineState(function: library.makeFunction(name: "resolveStereo")!)
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: "stereoVertex")
        descriptor.fragmentFunction = library.makeFunction(name: "stereoFragment")
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
        guard CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &cache) == kCVReturnSuccess else {
            throw StereoError("Couldn’t create the stereo texture cache")
        }
    }

    private func texture(_ buffer: CVPixelBuffer, format: MTLPixelFormat) throws -> CVMetalTexture {
        var result: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault, cache, buffer, nil, format,
                                                              CVPixelBufferGetWidth(buffer), CVPixelBufferGetHeight(buffer), 0, &result)
        guard status == kCVReturnSuccess, let result else { throw StereoError("Couldn’t upload a stereo frame") }
        return result
    }

    @discardableResult
    func render(frame: CVPixelBuffer, depth: CVPixelBuffer, into output: MTLTexture,
                drawable: CAMetalDrawable? = nil) throws -> MTLCommandBuffer {
        let image = try texture(frame, format: .bgra8Unorm)
        let depthFormat: MTLPixelFormat
        switch CVPixelBufferGetPixelFormatType(depth) {
        case kCVPixelFormatType_OneComponent16Half: depthFormat = .r16Float
        case kCVPixelFormatType_OneComponent32Float: depthFormat = .r32Float
        default: throw StereoError("Unsupported depth image format")
        }
        let depthTexture = try texture(depth, format: depthFormat)
        let width = CVPixelBufferGetWidth(frame), height = CVPixelBufferGetHeight(frame)
        guard width > 0, width <= 1920, height > 0, height <= 1080 else { throw StereoError("AI frames exceed 1080p per eye") }
        if eyeViews?.width != width * 2 || eyeViews?.height != height {
            projection = device.makeBuffer(length: width * 2 * height * MemoryLayout<UInt32>.size, options: .storageModePrivate)
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width * 2, height: height, mipmapped: false)
            descriptor.usage = [.shaderRead, .shaderWrite]
            descriptor.storageMode = .private
            eyeViews = device.makeTexture(descriptor: descriptor)
        }
        guard let projection, let eyeViews, let command = queue.makeCommandBuffer(), let clear = command.makeBlitCommandEncoder() else {
            throw StereoError("Couldn’t allocate stereo projection buffers")
        }
        clear.fill(buffer: projection, range: 0..<projection.length, value: 0)
        clear.endEncoding()
        var strength = depthStrength.rawValue
        for (state, columns) in [(projectionPipeline, width), (resolvePipeline, width * 2)] {
            guard let compute = command.makeComputeCommandEncoder() else { throw StereoError("Couldn’t project the stereo frame") }
            compute.setComputePipelineState(state)
            compute.setTexture(CVMetalTextureGetTexture(image), index: 0)
            compute.setTexture(state === projectionPipeline ? CVMetalTextureGetTexture(depthTexture) : eyeViews, index: 1)
            compute.setBuffer(projection, offset: 0, index: 0)
            compute.setBytes(&strength, length: MemoryLayout<Float>.size, index: 1)
            compute.dispatchThreads(MTLSize(width: columns, height: height, depth: 1), threadsPerThreadgroup: MTLSize(width: 16, height: 8, depth: 1))
            compute.endEncoding()
        }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = output
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        guard let encoder = command.makeRenderCommandEncoder(descriptor: pass) else {
            throw StereoError("Couldn’t render the stereo frame")
        }
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentTexture(eyeViews, index: 0)
        var settings = SIMD2<Float>(Float(output.width) / 2 / Float(output.height), depthStrength.rawValue)
        encoder.setFragmentBytes(&settings, length: MemoryLayout<SIMD2<Float>>.size, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
        if let drawable { command.present(drawable) }
        // Core Video wrappers and model buffers must survive the GPU command.
        command.addCompletedHandler { _ in withExtendedLifetime((image, depthTexture, frame, depth)) {} }
        command.commit()
        return command
    }
}

@MainActor
final class AIStereoView: MTKView, MTKViewDelegate {
    private let renderer: StereoMetalRenderer
    private var videoFrame: CVPixelBuffer?
    private var depth: CVPixelBuffer?
    var onFailure: ((Error) -> Void)?
    var depthStrength: StereoDepthStrength = .balanced {
        didSet { renderer.depthStrength = depthStrength; setNeedsDisplay(bounds) }
    }

    init(renderer: StereoMetalRenderer) {
        self.renderer = renderer
        super.init(frame: .zero, device: renderer.device)
        colorPixelFormat = .bgra8Unorm
        framebufferOnly = true
        isPaused = true
        enableSetNeedsDisplay = true
        delegate = self
        setAccessibilityLabel("AI Full-SBS video")
    }
    required init(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    func show(frame: CVPixelBuffer, depth: CVPixelBuffer) {
        self.videoFrame = frame; self.depth = depth
        setNeedsDisplay(bounds)
    }
    func draw(in view: MTKView) {
        guard let frame = videoFrame, let depth, let drawable = currentDrawable else { return }
        do { try renderer.render(frame: frame, depth: depth, into: drawable.texture, drawable: drawable) }
        catch { onFailure?(error) }
    }
    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}
}
