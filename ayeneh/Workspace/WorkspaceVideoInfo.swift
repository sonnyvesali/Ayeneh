import SwiftUI

struct WorkspaceVideoInfo: View {
    let video: RecentVideo
    let unavailable: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(video.filename).font(.headline).textSelection(.enabled)
            if unavailable {
                Label("File unavailable. Use Locate File to reconnect.", systemImage: "exclamationmark.triangle")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 9) {
                if let details = video.details {
                    info("Duration", timeLabel(details.duration))
                    if let width = details.width, let height = details.height { info("Resolution", "\(width) × \(height)") }
                    if let rate = details.frameRate { info("Frame rate", "\(rate.formatted(.number.precision(.fractionLength(0...2)))) fps") }
                    if let codec = details.codec { info("Codec", codec) }
                    if let size = details.fileSize { info("File size", ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)) }
                    if let captured = details.capturedAt { info("Recorded", captured.formatted(date: .abbreviated, time: .shortened)) }
                    if let device = details.device { info("Device", device) }
                    if let location = details.location { info("Location", location) }
                }
                info("Last opened", video.lastOpened.formatted(date: .abbreviated, time: .shortened))
                if video.position > 0 { info("Resume at", timeLabel(video.position)) }
            }
            .font(.callout)
            Divider()
            VStack(alignment: .leading, spacing: 5) {
                Text("File location").font(.caption).foregroundStyle(.secondary)
                Text(video.path).font(.caption).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(20).frame(width: 360, alignment: .leading)
    }

    private func info(_ label: String, _ value: String) -> some View {
        GridRow(alignment: .top) {
            Text(label).foregroundStyle(.secondary)
            Text(value).textSelection(.enabled)
        }
    }
}
