// swift-tools-version:5.9
// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint
// Copyright (C) 2026 Control Center Pro contributors

import PackageDescription

// Control Center Pro is a fork of vorssaint-utils. Upstream's sources under
// Sources/Vorssaint are a vendored engine layer we read and never edit; all our
// code lives in Sources/CCP*. This manifest is the one file both sides write to,
// so it is the expected merge conflict — our changes are fenced below and every
// one of them is recorded in PATCHES.md.

let package = Package(
    name: "ControlCenterPro",

    // ── CCP PATCH: deployment target 14.0 → 14.4 ───────────────────────────
    // The CoreAudio process-tap API the per-app audio mixer is built on
    // (CATapDescription) does not exist before 14.4. Upstream targets 14.0 and
    // gates the feature at runtime instead; we would rather the compiler know.
    // On merge: keep 14.4 unless upstream raises past it.
    platforms: [.macOS("14.4")],
    // ── END CCP PATCH ──────────────────────────────────────────────────────

    targets: [
        .systemLibrary(
            name: "VMStatisticsCompat",
            path: "Sources/VMStatisticsCompat"
        ),

        // ── CCP PATCH: upstream's `Vorssaint` executableTarget replaced ─────
        // Upstream ships everything as one executableTarget, and an executable
        // can't be imported by another target — so their engines would be
        // unreachable from ours. This declares the same sources as a library
        // instead, with their App/ and UI/ excluded: we build none of their
        // 46k lines of app and interface code, and the UI-free boundary the
        // fork depends on becomes something the compiler enforces rather than
        // something we remember.
        //
        // Two targets may not share source files, so this replaces their target
        // rather than sitting beside it. Their app is not buildable from this
        // fork, which is intended — we ship one app and it is ours.
        //
        // On merge: if upstream adds a top-level directory under
        // Sources/Vorssaint, decide whether it is engine or interface and
        // extend `exclude` accordingly. If the build breaks here, that is the
        // signal working as designed.
        .target(
            name: "VorssaintEngines",
            dependencies: ["VMStatisticsCompat"],
            path: "Sources/Vorssaint",
            exclude: [
                "App", "UI", "main.swift",

                // The BRIEF measured upstream's Services as "mostly UI-free"
                // by counting SwiftUI imports. Reference coupling is wider:
                // these files live in Core/ and Services/ but name a type that
                // lives in UI/, so they can't compile without it. Each is a
                // small presentation call-site inside an otherwise UI-free
                // service, which is what makes the upstream refactor in step 6
                // of the BRIEF worth proposing.
                //
                // This list is the honest measure of the boundary, and it
                // should shrink. Core/Permissions.swift is NOT on it: it is
                // foundational — excluding it caused 1336 errors on its own —
                // so its four lines of UI coupling are patched out instead.
                // Two files here are still needed for v1 and have their own
                // beads: Clipboard/ClipboardHistoryService.swift and
                // SystemMonitor/ProcessUsageService.swift. The rest are the
                // "Later/No" column of the BRIEF's engine inventory.
                "Support/SelfTest.swift",
                "Services/SettingsBackup.swift",
                "Services/ShortcutCapture.swift",
                "Services/CleaningMode/CleaningModeManager.swift",
                "Services/Clipboard/ClipboardHistoryService.swift",
                "Services/CommandBar/CommandBarCatalog.swift",
                "Services/CommandBar/CommandBarService.swift",
                "Services/DockPreview/DockPreviewService.swift",
                "Services/Finder/FinderCutPaste.swift",
                "Services/QuickTools/CameraPreviewService.swift",
                "Services/QuickTools/QuickLauncherService.swift",
                "Services/QuickTools/QuickTogglesService.swift",
                "Services/QuickTools/RecentCaptureService.swift",
                "Services/QuickTools/ScratchpadService.swift",
                "Services/QuickTools/ScreenshotEditorController.swift",
                "Services/QuickTools/ScreenshotQuickPreviewController.swift",
                "Services/RadialMenu/RadialMenuService.swift",
                "Services/RadialMenu/RadialNowPlayingService.swift",
                "Services/Recorder/RecorderEditorController.swift",
                "Services/Shelf/ShelfService.swift",
                "Services/Snippets/SnippetLibraryService.swift",
                "Services/Switcher/AppSwitcher.swift",
                "Services/SystemMonitor/ProcessUsageService.swift",

                // Second wave: these compile fine themselves but name a service
                // excluded above, so they fall out with it. Same rule applies —
                // when a leaker above comes back, check whether its dependents
                // can too.
                "Services/SelfUninstall.swift",
                "Services/TransientPaste.swift",
                "Services/Clipboard/ClipboardAutoClearService.swift",
                "Services/DockClick/DockClickService.swift",
                "Services/QuickTools/ScreenshotPinController.swift",
                "Services/QuickTools/ScreenshotService.swift",
                "Services/Recorder/ScreenRecorderService.swift",
                "Services/Snippets/TextSnippetService.swift",
                "Services/CommandBar/CommandBarExtras.swift",
                "Services/QuickTools/PastePlainService.swift",
                "Services/QuickTools/ScreenCaptureService.swift",
                "Services/QuickTools/ScreenshotSelectionController.swift",
                "Services/QuickTools/ColorSamplerService.swift",
                "Services/QuickTools/ScreenTextService.swift",
                "Services/QuickTools/ScreenshotScrollingCapture.swift",
            ]
        ),
        // ── END CCP PATCH ──────────────────────────────────────────────────

        // ── CCP TARGETS ────────────────────────────────────────────────────
        // Adapters over upstream's engines, plus the widget protocol, the
        // layout model, and settings. The only target that imports
        // VorssaintEngines — everything above the fork boundary stops here.
        .target(
            name: "CCPKit",
            dependencies: ["VorssaintEngines"],
            path: "Sources/CCPKit"
        ),

        // The glass shell, lanes, edit mode, and the design system. Imports
        // CCPKit and never VorssaintEngines: an upstream refactor should break
        // one adapter, not the interface.
        .target(
            name: "CCPUI",
            dependencies: ["CCPKit"],
            path: "Sources/CCPUI"
        ),

        .executableTarget(
            name: "ControlCenterPro",
            dependencies: ["CCPKit", "CCPUI"],
            path: "Sources/ControlCenterPro"
        ),

        .testTarget(
            name: "CCPKitTests",
            dependencies: ["CCPKit"],
            path: "Tests/CCPKitTests"
        ),
        // ── END CCP TARGETS ────────────────────────────────────────────────
    ]
)
