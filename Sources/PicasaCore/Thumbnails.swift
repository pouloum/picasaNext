import AVFoundation
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Thumbnail cache: one JPEG per media id, sharded as ab/cd/<id>.jpg to keep directories small
/// (a 2 TB library is typically 300k–800k items, ~20 KB each at 320 px → 6–16 GB).
public final class ThumbnailStore: Sendable {
    public let root: URL
    public static let maxPixel = 320

    init(root: URL) throws {
        self.root = root
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    public func url(id: Int64) -> URL {
        let h = String(format: "%04x", UInt16(truncatingIfNeeded: id))
        return root.appendingPathComponent(String(h.prefix(2)), isDirectory: true)
            .appendingPathComponent(String(h.suffix(2)), isDirectory: true)
            .appendingPathComponent("\(id).jpg")
    }

    public func exists(id: Int64) -> Bool { FileManager.default.fileExists(atPath: url(id: id).path) }

    func remove(id: Int64) { try? FileManager.default.removeItem(at: url(id: id)) }

    public func load(id: Int64) -> CGImage? {
        guard let src = CGImageSourceCreateWithURL(url(id: id) as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(src, 0, nil)
    }

    /// Stored in `media.thumb_state`.
    public enum Outcome: Int, Sendable { case done = 1, undecodable = 2, unreadable = 3 }

    /// Generates and writes the thumbnail.
    public func generate(id: Int64, url source: URL, kind: MediaKind) async -> Outcome {
        guard FileManager.default.isReadableFile(atPath: source.path) else { return .unreadable }
        let image: CGImage? = switch kind {
        case .image, .raw: Self.imageThumbnail(source, maxPixel: Self.maxPixel)
        case .video: await Self.videoThumbnail(source, maxPixel: Self.maxPixel)
        }
        guard let image else { return .undecodable }
        return write(image, to: url(id: id)) ? .done : .unreadable
    }

    /// ImageIO thumbnail: uses the embedded EXIF/RAW preview when it is large enough,
    /// otherwise decodes with subsampling. Orientation is applied.
    public static func imageThumbnail(_ url: URL, maxPixel: Int) -> CGImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageIfAbsent: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            kCGImageSourceShouldCacheImmediately: false,
        ]
        return CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary)
    }

    public static func videoThumbnail(_ url: URL, maxPixel: Int) async -> CGImage? {
        let asset = AVURLAsset(url: url)
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: maxPixel, height: maxPixel)
        gen.requestedTimeToleranceBefore = .positiveInfinity
        gen.requestedTimeToleranceAfter = .positiveInfinity
        let duration = (try? await asset.load(.duration))?.seconds ?? 0
        let t = CMTime(seconds: duration > 2 ? 1 : 0, preferredTimescale: 600)
        return try? await gen.image(at: t).image
    }

    func write(_ image: CGImage, to dest: URL) -> Bool {
        try? FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
        let tmp = dest.appendingPathExtension("tmp")
        guard let out = CGImageDestinationCreateWithURL(tmp as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else { return false }
        CGImageDestinationAddImage(out, image, [kCGImageDestinationLossyCompressionQuality: 0.7] as CFDictionary)
        guard CGImageDestinationFinalize(out) else { return false }
        return rename(tmp.path, dest.path) == 0 // atomic, same directory
    }
}
