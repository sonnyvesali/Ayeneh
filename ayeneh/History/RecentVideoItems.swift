import SwiftUI

/// Shared menu content for the toolbar and File menu.
struct RecentVideoItems: View {
    @ObservedObject var playback: PlaybackController
    @ObservedObject var history: WorkspaceHistoryStore

    var body: some View {
        if history.videos.isEmpty {
            Button("No Recent Videos") {}.disabled(true)
        } else {
            ForEach(history.videos) { video in
                Menu(video.filename) {
                    Text("Last opened \(video.lastOpened.formatted(date: .abbreviated, time: .shortened))")
                    Text(URL(fileURLWithPath: video.path).deletingLastPathComponent().path)
                    Divider()
                    Button("Open") { playback.openRecent(video) }
                    Button("Locate File…") { playback.locateVideo(video) }
                    Button("Remove from History") { playback.removeFromHistory(video) }
                }
            }
        }
    }
}
