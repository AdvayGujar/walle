import CoreGraphics
import Darwin
import Foundation
import ImageIO

public enum HEICWriterError: Error, CustomStringConvertible {
    case unreadableImage(String)
    case couldNotCreateImage
    case couldNotCreateDestination
    case destinationFailed
    case writeFailed(String)

    public var description: String {
        switch self {
        case .unreadableImage(let path):
            return "could not read upscaled image: " + path
        case .couldNotCreateImage:
            return "could not decode the upscaled image"
        case .couldNotCreateDestination:
            return "could not create a HEIC encoder"
        case .destinationFailed:
            return "could not encode HEIC"
        case .writeFailed(let why):
            return "could not write HEIC: " + why
        }
    }
}

/// Writes the upscaler's PNG/JPEG result as HEIC, carrying the source image's
/// colour profile across. Upscayl's CLI strips the profile, so this is the step
/// that keeps an sRGB or Display P3 wallpaper from turning into an untagged file.
public enum HEICWriter {
    public static func profileName(for source: URL) -> String? {
        guard let imageSource = CGImageSourceCreateWithURL(source as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil)
                as? [CFString: Any] else {
            return nil
        }
        return properties[kCGImagePropertyProfileName] as? String
    }

    public static func write(imageURL: URL, to output: URL,
                             quality: Double, sourceProfile: String?) throws {
        guard let imageSource = CGImageSourceCreateWithURL(imageURL as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(imageSource, 0, nil) else {
            throw HEICWriterError.unreadableImage(imageURL.path)
        }

        let space = colorSpace(for: sourceProfile)
            ?? image.colorSpace
            ?? CGColorSpace(name: CGColorSpace.sRGB)!
        let tagged = image.copy(colorSpace: space) ?? image

        let directory = output.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let temporary = directory.appendingPathComponent(
            ".walle-heic-\(UUID().uuidString).heic")
        defer { try? FileManager.default.removeItem(at: temporary) }

        guard let destination = CGImageDestinationCreateWithURL(
            temporary as CFURL, "public.heic" as CFString, 1, nil) else {
            throw HEICWriterError.couldNotCreateDestination
        }
        let properties: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: min(max(quality, 0), 1),
        ]
        CGImageDestinationAddImage(destination, tagged, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw HEICWriterError.destinationFailed
        }
        guard rename(temporary.path, output.path) == 0 else {
            throw HEICWriterError.writeFailed(String(cString: strerror(errno)))
        }
    }

    private static func colorSpace(for profile: String?) -> CGColorSpace? {
        let name = profile?.lowercased() ?? ""
        if name.contains("p3") {
            return CGColorSpace(name: CGColorSpace.displayP3)
        }
        if name.isEmpty || name.contains("srgb") {
            return CGColorSpace(name: CGColorSpace.sRGB)
        }
        return nil
    }
}
