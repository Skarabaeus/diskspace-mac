# DiskSpace

A lightweight macOS app that scans a folder and shows a tree of files and directories sorted by size, so you can quickly find what's consuming disk space.

## Features

- Expandable tree view with folders and files sorted largest-first at every level
- Displays allocated disk size (not logical size), matching what Finder reports
- Correctly handles hard links (counted once), directory symlinks (not followed to avoid double-counting), and cross-device mount points (skipped)
- Live progress indicator while scanning; scan can be cancelled at any time
- "Show in Finder" button to reveal the scanned folder
- Keyboard shortcut: `Cmd+O` to open a folder

## Requirements

- macOS 13 Ventura or later
- Xcode 15 or later (to build from source)

## Build

### Using the build script (recommended)

```bash
./build.sh
```

This runs `xcodebuild` in Release configuration and places the `.app` bundle under `build/`. An optional argument overrides the configuration:

```bash
./build.sh Debug
```

### Using Xcode

Open `DiskSpace.xcodeproj`, select the **DiskSpace** scheme, and build with `Cmd+B`.

### Using Swift Package Manager

```bash
swift build -c release
```

The executable is placed at `.build/release/DiskSpace`. Note: the SPM build produces a command-line executable only, not a full `.app` bundle.

## Project structure

```
DiskSpace/
  DiskSpaceApp.swift   – App entry point
  ContentView.swift    – UI and scan view model
  FolderScanner.swift  – Recursive directory scanner (async, allocation-aware)
  FolderNode.swift     – Tree node model
```
