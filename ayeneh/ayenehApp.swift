//
//  ayenehApp.swift
//  ayeneh
//
//  Created by Sonny Vesali on 10/11/26.
//

import SwiftUI

@main
struct ayenehApp: App {
    @StateObject private var history = WorkspaceHistoryStore()
    @StateObject private var reviewTemplates: ReviewTemplateStore
    @StateObject private var clips: ClipStore

    init() {
        let templates = ReviewTemplateStore()
        _reviewTemplates = StateObject(wrappedValue: templates)
        _clips = StateObject(wrappedValue: ClipStore(profileID: templates.profileID))
    }

    var body: some Scene {
        WindowGroup {
            VideoWorkspace(history: history, reviewTemplates: reviewTemplates, clips: clips)
        }
        .defaultSize(width: 1100, height: 760)
        .commands { PlaybackCommands() }
    }
}
