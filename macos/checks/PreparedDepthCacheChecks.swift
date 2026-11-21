import Foundation

@main
struct PreparedDepthCacheChecks {
    static func main() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("shoebox-depth-cache-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let video = root.appendingPathComponent("Original movie.mkv")
        try Data([1, 2, 3]).write(to: video)
        let cache = try PreparedDepthCache(source: video, strength: .balanced, root: root.appendingPathComponent("cache"))
        let other = try PreparedDepthCache(source: video, strength: .strong, root: root.appendingPathComponent("cache"))
        precondition(cache.directory == other.directory && cache.playbackURL != other.playbackURL, "Strengths must reuse depth without reusing the wrong rendered file")
        precondition(!cache.ready)
        try FileManager.default.createDirectory(at: cache.directory, withIntermediateDirectories: true)
        let valid = PreparedDepthManifest(model: PreparedDepthCache.model, source: cache.identity, fps: 23.976, frames: 64,
            width: 700, height: 392, cropX: 0, cropY: 0, cropWidth: 700, cropHeight: 392, low: 0, high: 1)
        try Data([1]).write(to: cache.depthURL)
        try cache.publish(valid)
        precondition(!cache.ready, "Depth alone must not be marked ready for playback")
        try Data([1]).write(to: cache.playbackURL)
        precondition(cache.ready && !other.ready)
        let invalid = PreparedDepthManifest(model: PreparedDepthCache.model, source: cache.identity, fps: 24, frames: 1,
            width: 700, height: 392, cropX: Int.max, cropY: 0, cropWidth: Int.max, cropHeight: 392, low: 0, high: 1)
        precondition(!invalid.valid, "Malformed crop metadata must be rejected without overflow")
        try Data("broken json".utf8).write(to: cache.manifestURL)
        precondition(cache.manifest == nil && !cache.ready)
        try cache.publish(valid)
        try Data([4, 5, 6, 7]).write(to: video)
        let updated = try PreparedDepthCache(source: video, strength: .balanced, root: root.appendingPathComponent("cache"))
        precondition(updated.directory != cache.directory, "Changed sources must invalidate cached results")
        precondition(!cache.ready, "Existing cache objects must reject a source modified after lookup")
        do { try cache.checkUnchanged(); fatalError("Source change was not detected") } catch {}
        do { _ = try PreparedDepthCache(source: URL(string: "http://127.0.0.1/media/video")!, strength: .balanced); fatalError("Streaming source was accepted") } catch {}
        let original = try Data(contentsOf: video)
        precondition(original == Data([4, 5, 6, 7]), "Cache operations must not modify the source")
        print("Prepared-depth cache checks passed: reuse, strength isolation, invalidation, corruption, bounds, local-only input and unchanged source.")
    }
}
