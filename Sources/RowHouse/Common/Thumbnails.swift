import AppKit
import QuickLookThumbnailing
import RowHouseCore
import SwiftUI

/// Loads and caches attachment thumbnails off the main thread. iCloud may need to download the file
/// first; that happens transparently on the background read.
@MainActor
final class ThumbnailCache {
    static let shared = ThumbnailCache()
    private let cache = NSCache<NSString, NSImage>()
    private var inFlight: [String: [(NSImage?) -> Void]] = [:]

    private init() {
        cache.countLimit = 600
    }

    func cached(_ url: URL, size: CGFloat) -> NSImage? {
        cache.object(forKey: key(url, size) as NSString)
    }

    private func key(_ url: URL, _ size: CGFloat) -> String {
        "\(url.path)#\(Int(size))"
    }

    func load(_ url: URL, size: CGFloat, completion: @escaping (NSImage?) -> Void) {
        let k = key(url, size)
        if let hit = cache.object(forKey: k as NSString) {
            completion(hit)
            return
        }
        if inFlight[k] != nil {
            inFlight[k]?.append(completion)
            return
        }
        inFlight[k] = [completion]
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        Task.detached(priority: .utility) {
            let image = await Self.makeThumbnail(url: url, size: size, scale: scale)
            await MainActor.run {
                if let image { self.cache.setObject(image, forKey: k as NSString) }
                let callbacks = self.inFlight.removeValue(forKey: k) ?? []
                for cb in callbacks { cb(image) }
            }
        }
    }

    nonisolated private static func makeThumbnail(url: URL, size: CGFloat, scale: CGFloat) async -> NSImage? {
        let pixel = size * scale
        if let source = CGImageSourceCreateWithURL(url as CFURL, nil) {
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: pixel,
            ]
            if let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) {
                return NSImage(cgImage: cg, size: NSSize(width: CGFloat(cg.width) / scale, height: CGFloat(cg.height) / scale))
            }
        }
        let request = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: size, height: size), scale: scale, representationTypes: .thumbnail)
        if let rep = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request) {
            return rep.nsImage
        }
        return NSWorkspace.shared.icon(forFile: url.path)
    }
}

/// SwiftUI thumbnail for an attachment.
struct AttachmentThumbnail: View {
    let url: URL
    let attachment: AttachmentInfo
    var size: CGFloat = 64
    var contentMode: ContentMode = .fill
    @State private var image: NSImage?

    var body: some View {
        ZStack {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: contentMode)
            } else {
                Rectangle().fill(Color.primary.opacity(0.06))
                Image(systemName: attachment.isImage ? "photo" : "doc")
                    .foregroundStyle(.secondary)
            }
        }
        .clipped()
        .task(id: url) {
            image = ThumbnailCache.shared.cached(url, size: size)
            if image == nil {
                ThumbnailCache.shared.load(url, size: size) { image = $0 }
            }
        }
    }
}
