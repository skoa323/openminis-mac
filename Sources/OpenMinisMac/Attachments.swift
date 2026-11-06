import Foundation
import AppKit

/// Image attachments are stored as JPEG files under Application Support,
/// referenced from messages by file name, and base64-encoded only at request time.
enum Attachments {
    static var dir: URL {
        let d = AppStore.supportDir.appendingPathComponent("attachments", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    static func url(_ name: String) -> URL { dir.appendingPathComponent(name) }

    /// Longest side is capped so requests stay small; returns the stored file name.
    static func save(_ image: NSImage, maxSide: CGFloat = 2048) -> String? {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let w = CGFloat(cg.width), h = CGFloat(cg.height)
        let scale = min(1, maxSide / max(w, h))
        let tw = max(1, Int(w * scale)), th = max(1, Int(h * scale))
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: tw, pixelsHigh: th,
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor.white.setFill()
        NSRect(x: 0, y: 0, width: tw, height: th).fill()
        NSGraphicsContext.current?.cgContext.draw(cg, in: CGRect(x: 0, y: 0, width: tw, height: th))
        NSGraphicsContext.restoreGraphicsState()
        guard let data = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.85]) else { return nil }
        let name = UUID().uuidString + ".jpg"
        do { try data.write(to: url(name)) } catch { return nil }
        return name
    }

    static func save(fileURL: URL) -> String? {
        guard let img = NSImage(contentsOf: fileURL) else { return nil }
        return save(img)
    }

    static func base64(_ name: String) -> String? {
        (try? Data(contentsOf: url(name)))?.base64EncodedString()
    }

    static func image(_ name: String) -> NSImage? { NSImage(contentsOf: url(name)) }

    /// Saves images found on a pasteboard (image files or raw image data) and returns their names.
    /// Returns [] when the pasteboard is really text (rich-text copies often carry an image rendition too)
    /// or holds non-image files, so the caller can fall back to the default behaviour.
    static func importImages(from pb: NSPasteboard) -> [String] {
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
           !urls.isEmpty {
            let imgs = urls.filter { imageExtensions.contains($0.pathExtension.lowercased()) }
            return imgs.compactMap { save(fileURL: $0) }
        }
        if pb.string(forType: .string) != nil { return [] }
        if let objs = pb.readObjects(forClasses: [NSImage.self]) as? [NSImage], !objs.isEmpty {
            return objs.compactMap { save($0) }
        }
        return []
    }

    static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "heic", "heif", "tiff", "tif", "bmp", "webp"]
}
