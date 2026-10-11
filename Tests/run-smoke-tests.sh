#!/bin/zsh
set -eu
cd "${0:A:h}/.."
test_dir=$(mktemp -d /private/tmp/ayeneh-tests.XXXXXX)
trap 'rm -rf "$test_dir"' EXIT
xcrun swiftc -parse-as-library -default-isolation MainActor \
    -module-cache-path "$test_dir/module-cache" \
    ayeneh/Playback/PlaybackController.swift \
    ayeneh/History/WorkspaceHistoryStore.swift \
    ayeneh/History/VideoInspector.swift \
    ayeneh/Review/ReviewTemplateStore.swift \
    ayeneh/Review/ClipStore.swift \
    ayeneh/Review/ClipReviewController.swift \
    ayeneh/Review/ClipExportController.swift \
    ayeneh/Workspace/TimelineScale.swift \
    Tests/PlaybackSmokeTests.swift Tests/WorkspaceHistoryTests.swift Tests/ReviewTemplateTests.swift Tests/ClipReviewTests.swift Tests/ClipExportTests.swift -o "$test_dir/playback-tests"
"$test_dir/playback-tests"
