# Ayeneh

A native macOS app for reviewing local videos, making clips, and organizing them with reusable review templates.

Built with Swift, SwiftUI, AVFoundation, and AVKit. Runs on **macOS 14 or later**, with no third-party dependencies or sign-in.

## Features

- **Video workspace:** native file picker, large video viewport, playback speeds, forward/reverse shuttling, frame stepping, and an animated timeline with fine scrubbing.
- **Workspace history:** thumbnails, embedded recording metadata, last-opened dates, and saved playback positions. The app restores the workspace or video you left open.
- **Review templates:** reusable clip-type hierarchies, assessments, and colors. Assign a template to a video from Workspace.
- **Clip review:** mark in/out points or draw a range, refine its boundaries on a focused timeline, loop it, and add a title, category, assessment, or note. Changes save automatically.
- **Visual organization:** inherited type colors, assessment indicators, and hover details make clips easy to identify.
- **Local export:** create standalone MP4 clips, organized by type and assessment, with a JSON metadata index. Export runs in the background with progress and cancellation.

## Getting started

### Requirements

- A Mac running macOS 14 or later.
- Xcode 26 or later for development; the project uses Swift's default main-actor isolation setting.

### Run in Xcode

1. Clone the repository:

   ```sh
   git clone https://github.com/sonnyvesali/Ayeneh.git
   cd Ayeneh
   ```

2. Open `ayeneh.xcodeproj`.
3. Select the **ayeneh** scheme and **My Mac**, then run.
4. Choose **Open Video** or press **⌘O** to open a local video.

If Xcode asks for signing configuration, select your development team or use local signing for development.

### Build from the command line

```sh
xcodebuild \
  -project ayeneh.xcodeproj \
  -scheme ayeneh \
  -configuration Debug \
  -destination 'platform=macOS' \
  -derivedDataPath .build \
  CODE_SIGN_IDENTITY=- build
```

The app is built at `.build/Build/Products/Debug/ayeneh.app`. Change `Debug` to `Release` for a release build.

## Review workflow

1. Open **Review Templates** in the workspace sidebar to create a template. Clip types can be nested; assessments are flat options. Top-level types receive distinct colors, and children inherit their parent's color unless overridden.
2. Assign the template using the picker on a video row, then open the video.
3. Press **I** and **O** to set a clip's boundaries, or drag across the clip-selection lane beneath the timeline ruler.
4. The timeline focuses on the clip automatically. Drag the boundary handles to refine it; use **Overview** to see the full video or **Fit Clip** to focus again.
5. Add categories, assessments, and notes in the **Clips** panel. Valid clips and edits save automatically. New selections loop by default when played.
6. Click empty timeline space or press **Escape** to deselect and return to the overview. **Delete** immediately removes the selected clip without a confirmation dialog.

Clips remain associations with the original video until you export them. A lone in-point is temporary until an out-point creates a valid range. Clips may remain uncategorized or unassessed.

Returning to Workspace preserves clips and playback position. Reopening a viewed video resumes at its saved position, paused. If a video moves or its drive disconnects, use **Locate File…** to restore its association. Removing a video from history leaves the original file intact but removes access to its clip associations.

## Export clips

Choose **Export Clips** in the video toolbar, select the clips, name the session folder, and choose a destination.

Enable clip-type folders to reproduce the full type hierarchy and optionally group by assessment. Disable both options for a flat export. For example:

```text
Session name/
  Forehand/
    Fast incoming/
      Good/
        Clip — source time — unique ID.mp4
  Uncategorized/
    Not assessed/
      Clip — source time — unique ID.mp4
  clips.json
```

Each batch creates a new folder, adding a number if the name already exists. The `clips.json` index includes relative file paths, original clip ranges and identities, titles, notes, type paths, assessments, and a snapshot of the associated review templates and colors.

Exports use a snapshot of the clips and templates taken when the export sheet opens. You can keep reviewing or switch videos while exporting. The toolbar status button shows progress, offers cancellation, and reveals the output in Finder. Cancellation or failure retains completed clips and records the partial result in the index.

MP4 export re-encodes using AVFoundation's highest-quality preset, preserving source resolution, presentation orientation, and audio where supported. Trim precision follows the source's frames and audio samples. This is not a lossless archival export, and HDR/color handling follows the preset's behavior. Batches do not resume after relaunch; abrupt termination can leave an unfinished file or index.

## Keyboard shortcuts

| Action | Shortcut |
| --- | --- |
| Open video | ⌘O |
| Back to Workspace | ⌘[ |
| Play / pause | Space |
| Shuttle backward / pause / forward | J / K / L |
| Previous / next frame | ← / → |
| Playback speeds: 0.25×, 1×, 2×, 3×, 4× | ⌘1 through ⌘5 |
| Mark clip in / out | I / O |
| New three-second clip | ⇧⌘N |
| Toggle selected-clip looping | R |
| Deselect clip | Escape |
| Delete selected clip / clear incomplete range | Delete |

Shuttling starts at 2× and cycles through 3×, 4×, and 1×. Pressing the opposite shuttle button during fast playback restores normal 1× forward playback. Play/pause also resets the speed to 1×. Single-key playback and clip shortcuts are disabled while editing clip text.

## Local data and privacy

Original videos are read in place: Ayeneh does not upload them or duplicate them on import. Standalone media files are created only when you export clips.

Workspace history, playback positions, templates, and clip associations are stored in local preferences. Templates and clips belong to a persistent local profile, with no account required. Small JPEG thumbnails are stored in the app's local cache.

The app uses sandboxed, security-scoped file access. The native destination picker grants write access for exports; source videos remain untouched. Recording dates, device information, and location are shown only when embedded in the video. Location is not sent to a geocoding service.

## Project structure

```text
ayeneh/
  Playback/       Media loading, player state, seeks, looping, and commands
  History/        Local workspace history, bookmarks, thumbnails, and metadata
  Review/         Templates, clip persistence, autosave, and export logic
  Workspace/      SwiftUI workspace, video viewport, timeline, and review panels
Tests/            Native playback, persistence, review, and export smoke tests
Design/AppIcon/   Editable monochrome mirror SVGs and Icon Composer source layers
```

Playback and persistence logic are separated from the SwiftUI views. Preview workspaces use isolated preferences and do not restore real workspace history.

The mirror artwork is an initial vector design. Its transparent layers are prepared for Icon Composer; the final native Liquid Glass app icon has not yet been integrated. See [the icon source notes](Design/AppIcon/README.md).

## Tests

Run on macOS with Xcode's command-line tools selected:

```sh
zsh Tests/run-smoke-tests.sh
```

The suite generates temporary videos and uses isolated preferences and thumbnail caches. It checks playback and frame stepping, timeline mapping, workspace restoration, metadata, template hierarchies and colors, clip autosave and looping, and actual MP4 exports—including decoded trim boundaries, audio, orientation, folder organization, cancellation, and source preservation.

These tests require access to macOS media services and may fail in a restrictive execution sandbox.

## Current limitations

- Codec support and frame stepping depend on AVFoundation. Unsupported shuttle rates use silent timed seeks, and loops may have a brief decoding gap.
- An abrupt crash may lose up to five seconds of playback position. When two windows edit the same video, the most recent position checkpoint or clip save wins.
- Export handles one video and one batch per window. A cross-video clip library, timestamped annotations, cloud synchronization, and automatic analysis are not implemented.
