import AppKit
import AVFoundation

struct VideoDetails: Codable {
    var duration: Double
    var width: Int?
    var height: Int?
    var frameRate: Double?
    var codec: String?
    var fileSize: Int?
    var fileModified: Date?
    var capturedAt: Date?
    var device: String?
    var location: String?
}

struct VideoPreview {
    var image: NSImage?
    var unavailable: Bool
}

enum VideoInspector {
    static func details(for url: URL) async throws -> VideoDetails {
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration).seconds
        let attributes = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        var details = VideoDetails(duration: duration.isFinite ? duration : 0,
                                   fileSize: attributes?.fileSize, fileModified: attributes?.contentModificationDate)
        if let track = try await asset.loadTracks(withMediaType: .video).first {
            let size = try await track.load(.naturalSize)
            let transform = try await track.load(.preferredTransform)
            let display = CGRect(origin: .zero, size: size).applying(transform)
            details.width = Int(abs(display.width).rounded())
            details.height = Int(abs(display.height).rounded())
            let rate = Double(try await track.load(.nominalFrameRate))
            if rate.isFinite, rate > 0 { details.frameRate = rate }
            if let format = try await track.load(.formatDescriptions).first {
                details.codec = codecLabel(CMFormatDescriptionGetMediaSubType(format))
            }
        }
        let metadata = (try? await asset.load(.metadata)) ?? []
        let common = (try? await asset.load(.commonMetadata)) ?? []
        let quickTimeDate = await string(.quickTimeMetadataCreationDate, in: metadata)
        let commonDate = await string(.commonIdentifierCreationDate, in: common)
        let date = quickTimeDate ?? commonDate
        details.capturedAt = date.flatMap(parseCaptureDate)
        let make = await string(.quickTimeMetadataMake, in: metadata)
        let model = await string(.quickTimeMetadataModel, in: metadata)
        if let model { details.device = model }
        else { details.device = make }
        let name = await string(.quickTimeMetadataLocationName, in: metadata)
        let coordinates = await string(.quickTimeMetadataLocationISO6709, in: metadata)
        details.location = name ?? coordinates.flatMap(locationLabel)
        return details
    }

    static func thumbnail(for url: URL, duration: Double) async throws -> Data? {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 640, height: 640)
        let time = CMTime(seconds: min(1, max(0, duration / 10)), preferredTimescale: 600)
        let result = try await generator.image(at: time)
        try Task.checkCancellation()
        return NSBitmapImageRep(cgImage: result.image).representation(using: .jpeg, properties: [.compressionFactor: 0.75])
    }

    private static func string(_ identifier: AVMetadataIdentifier, in items: [AVMetadataItem]) async -> String? {
        for item in AVMetadataItem.metadataItems(from: items, filteredByIdentifier: identifier) {
            if let value = try? await item.load(.stringValue), !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return value.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return nil
    }

    static func parseCaptureDate(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: value) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)
    }

    static func locationLabel(_ value: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: "^([+-]\\d{2}(?:\\.\\d+)?)([+-]\\d{3}(?:\\.\\d+)?)(?:[+-]\\d+(?:\\.\\d+)?)?/$"),
              let match = regex.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)),
              let latRange = Range(match.range(at: 1), in: value),
              let lonRange = Range(match.range(at: 2), in: value),
              let latitude = Double(value[latRange]), let longitude = Double(value[lonRange]),
              abs(latitude) <= 90, abs(longitude) <= 180 else { return nil }
        return String(format: "%.4f° %@, %.4f° %@", abs(latitude), latitude < 0 ? "S" : "N",
                      abs(longitude), longitude < 0 ? "W" : "E")
    }

    private static func codecLabel(_ code: FourCharCode) -> String {
        let names: [FourCharCode: String] = [kCMVideoCodecType_H264: "H.264", kCMVideoCodecType_HEVC: "HEVC",
                                           kCMVideoCodecType_AppleProRes422: "ProRes 422",
                                           kCMVideoCodecType_AppleProRes422HQ: "ProRes 422 HQ",
                                           kCMVideoCodecType_AppleProRes4444: "ProRes 4444"]
        if let name = names[code] { return name }
        let bytes = (0..<4).map { UInt8((code >> (24 - $0 * 8)) & 0xff) }
        return String(bytes: bytes, encoding: .ascii)?.trimmingCharacters(in: .whitespaces) ?? "Video"
    }
}
