import Foundation
import CryptoKit

struct DepthSourceIdentity: Codable, Equatable {
    let path: String
    let size: UInt64
    let modified: Double
    let inode: UInt64

    init(_ url: URL) throws {
        guard url.isFileURL else { throw StereoError("Preprocessing needs a completed local video") }
        let resolved = url.resolvingSymlinksInPath().standardizedFileURL
        let attributes = try FileManager.default.attributesOfItem(atPath: resolved.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              let size = attributes[.size] as? NSNumber, size.uint64Value > 0,
              let modified = attributes[.modificationDate] as? Date else {
            throw StereoError("Choose a completed local video file")
        }
        path = resolved.path
        self.size = size.uint64Value
        self.modified = modified.timeIntervalSince1970
        inode = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0
    }
}

struct PreparedDepthManifest: Codable {
    let model: String
    let source: DepthSourceIdentity
    let fps: Double
    let frames: Int
    let width: Int
    let height: Int
    let cropX: Int
    let cropY: Int
    let cropWidth: Int
    let cropHeight: Int
    let low: Float
    let high: Float

    var valid: Bool {
        model == PreparedDepthCache.model && fps.isFinite && fps > 0 && fps <= 240 && frames > 0 && frames <= 240 * 3600 * 48
        && width == 700 && height == 392 && cropX >= 0 && cropX <= width && cropY >= 0 && cropY <= height
        && cropWidth > 0 && cropWidth <= width && cropHeight > 0 && cropHeight <= height
        && cropX + cropWidth <= width && cropY + cropHeight <= height
        && low.isFinite && high.isFinite && high > low
    }
}

struct PreparedDepthCache {
    static let model = "vda-small-32-700x392-25687536-v1"
    let identity: DepthSourceIdentity
    let directory: URL
    let strength: StereoDepthStrength

    init(source: URL, strength: StereoDepthStrength, root: URL? = nil) throws {
        identity = try DepthSourceIdentity(source)
        self.strength = strength
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        var data = try encoder.encode(identity)
        data.append(Data(Self.model.utf8))
        let key = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let base = root ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("com.theanam.shoebox/Prepared3D", isDirectory: true)
        directory = base.appendingPathComponent(key, isDirectory: true)
    }

    var depthURL: URL { directory.appendingPathComponent("depth.mkv") }
    var manifestURL: URL { directory.appendingPathComponent("manifest.json") }
    var playbackURL: URL {
        directory.appendingPathComponent("sbs-\(Int((strength.rawValue * 10000).rounded())).mkv")
    }
    var manifest: PreparedDepthManifest? {
        guard (try? DepthSourceIdentity(URL(fileURLWithPath: identity.path))) == identity,
              let data = try? Data(contentsOf: manifestURL),
              let value = try? JSONDecoder().decode(PreparedDepthManifest.self, from: data),
              value.valid, value.source == identity,
              FileManager.default.fileExists(atPath: depthURL.path) else { return nil }
        return value
    }
    var ready: Bool {
        manifest != nil && ((try? playbackURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) > 0
    }
    func checkUnchanged() throws {
        guard try DepthSourceIdentity(URL(fileURLWithPath: identity.path)) == identity else {
            throw StereoError("The source video changed during preparation. Please try again.")
        }
    }
    func publish(_ value: PreparedDepthManifest) throws {
        guard value.valid, value.source == identity else { throw StereoError("Invalid prepared-depth metadata") }
        try checkUnchanged()
        try JSONEncoder().encode(value).write(to: manifestURL, options: .atomic)
    }
}
