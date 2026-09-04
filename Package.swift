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

    // ── CCP PATCH: deployment target 14.0 → 26.0 ──────────────────────────
    // Was 14.4, the floor for the CoreAudio process-tap API (CATapDescription)
    // the audio mixer needs. Raised to 26.0 so the app can use the macOS 26
    // SwiftUI surface — native `reorderable()` for lane drag reorder (ccp-m53),
    // and the Liquid Glass materials the panel is drawn with.
    //
    // Verified: the raise adds no errors. It does surface 7 deprecation sites,
    // all inside vendored upstream we never edit (RecorderComposer's
    // AVMutableVideoComposition, HomebrewManager's init(contentsOfFile:)), so
    // they are expected noise rather than something to fix here.
    //
    // On merge: keep 26.0 unless upstream raises past it.
    platforms: [.macOS("26.0")],
    // ── END CCP PATCH ──────────────────────────────────────────────────────

    // ── CCP PATCH: one dependency upstream does not have ───────────────────
    // psymail-mini ships the same sources twice: as its own menu-bar app, and
    // through a SwiftPM manifest as PsymailKit, a library a host can embed. The
    // mail widget is that host — CCP carries the inbox rather than launching a
    // second menu-bar app beside its own.
    //
    // A path dependency, not a URL: the two repositories are developed as a
    // pair in sibling checkouts, and a revision pin would mean a push and a
    // bump for every change made while building a widget against it. The cost
    // is that a checkout of CCP alone does not build — see PATCHES.md.
    //
    // On merge: upstream has no dependencies, so this block is ours entirely.
    dependencies: [
        .package(path: "../psymail-mini"),

        // The scratchpad's editor. A live-styled Markdown surface on TextKit 2
        // — the markers hide as you type and come back when the caret lands on
        // them — which is a thing the SwiftUI TextEditor cannot be made to do.
        //
        // A URL dependency rather than a vendored copy: unlike the Vorssaint
        // engines we fork, this is a library we consume unchanged and want
        // updates from. Pinned exact while it is pre-1.0 and its API is still
        // settling.
        //
        // Apache-2.0, which is one-way compatible with our GPL-3.0-or-later.
        .package(url: "https://github.com/nodes-app/swift-markdown-engine",
                 exact: "0.12.0"),
    ],

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
            //
            // The target's path is Sources rather than Sources/Vorssaint so it
            // can compile a second directory, VorssaintBridge, as a module-mate
            // of upstream. Every upstream type is internal, so nothing in the
            // engine layer is visible across a module boundary; the bridge sits
            // inside the module and re-exports what CCPKit needs as public. It
            // is the reason every exclude below carries a "Vorssaint/" prefix.
            // See PATCHES.md.
            path: "Sources",
            exclude: [
                "Vorssaint/App", "Vorssaint/UI", "Vorssaint/main.swift",

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
                // One file here is still needed for v1 and has its own bead:
                // SystemMonitor/ProcessUsageService.swift. The clipboard pair
                // previously here was patched in ccp-8ld.5. The rest are the
                // "Later/No" column of the BRIEF's engine inventory.
                "Vorssaint/Support/SelfTest.swift",
                "Vorssaint/Services/SettingsBackup.swift",
                "Vorssaint/Services/ShortcutCapture.swift",
                "Vorssaint/Services/CleaningMode/CleaningModeManager.swift",
                "Vorssaint/Services/CommandBar/CommandBarCatalog.swift",
                "Vorssaint/Services/CommandBar/CommandBarService.swift",
                "Vorssaint/Services/DockPreview/DockPreviewService.swift",
                "Vorssaint/Services/Finder/FinderCutPaste.swift",
                "Vorssaint/Services/QuickTools/CameraPreviewService.swift",
                "Vorssaint/Services/QuickTools/QuickLauncherService.swift",
                "Vorssaint/Services/QuickTools/QuickTogglesService.swift",
                "Vorssaint/Services/QuickTools/RecentCaptureService.swift",
                "Vorssaint/Services/QuickTools/ScratchpadService.swift",
                "Vorssaint/Services/QuickTools/ScreenshotEditorController.swift",
                "Vorssaint/Services/QuickTools/ScreenshotQuickPreviewController.swift",
                "Vorssaint/Services/RadialMenu/RadialMenuService.swift",
                "Vorssaint/Services/RadialMenu/RadialNowPlayingService.swift",
                "Vorssaint/Services/Recorder/RecorderEditorController.swift",
                "Vorssaint/Services/Shelf/ShelfService.swift",
                "Vorssaint/Services/Snippets/SnippetLibraryService.swift",
                "Vorssaint/Services/Switcher/AppSwitcher.swift",
                "Vorssaint/Services/SystemMonitor/ProcessUsageService.swift",

                // Second wave: these compile fine themselves but name a service
                // excluded above, so they fall out with it. Same rule applies —
                // when a leaker above comes back, check whether its dependents
                // can too.
                "Vorssaint/Services/SelfUninstall.swift",
                "Vorssaint/Services/TransientPaste.swift",
                "Vorssaint/Services/DockClick/DockClickService.swift",
                "Vorssaint/Services/QuickTools/ScreenshotPinController.swift",
                "Vorssaint/Services/QuickTools/ScreenshotService.swift",
                "Vorssaint/Services/Recorder/ScreenRecorderService.swift",
                "Vorssaint/Services/Snippets/TextSnippetService.swift",
                "Vorssaint/Services/CommandBar/CommandBarExtras.swift",
                "Vorssaint/Services/QuickTools/PastePlainService.swift",
                "Vorssaint/Services/QuickTools/ScreenCaptureService.swift",
                "Vorssaint/Services/QuickTools/ScreenshotSelectionController.swift",
                "Vorssaint/Services/QuickTools/ColorSamplerService.swift",
                "Vorssaint/Services/QuickTools/ScreenTextService.swift",
                "Vorssaint/Services/QuickTools/ScreenshotScrollingCapture.swift",

                // WhatsApp downloads organizer — declares NSDocuments/
                // NSDesktop/NSDownloads folder usage and touches the file
                // system at launch via FeatureRuntime → Cleaner binding.
                // CCP's panel (CCPKit/CCPUI) never uses it, and its
                // destination probing is what prompts for Documents every
                // launch when built ad-hoc (ccp-1kb). Keep the engine out
                // until CCP needs it; the strings and support files stay.
                "Vorssaint/Services/ManagedDownloads/WhatsAppDownloadManager.swift",
                "Vorssaint/Services/ManagedDownloads/WhatsAppDownloadOrganizer.swift",
                "Vorssaint/Services/ManagedDownloads/WhatsAppDownloadScheduler.swift",
                "Vorssaint/Services/ManagedDownloads/WhatsAppDownloadSupport.swift",

                // Ours: the bridge's own documentation, not a source file.
                "VorssaintBridge/README.md",

                // Siblings of Vorssaint under path: "Sources" that are not part
                // of this target's sources — without these SwiftPM warns "found
                // 34 file(s) which are unhandled" and hides a real "unexpected
                // input file" when an upstream file is missed in the lists above.
                "CCPKit",
                "CCPUI",
                "ControlCenterPro",
                "FanControlHelper",
                "VMStatisticsCompat",
            ],
            // Upstream's sources, plus our visibility shims. Two directories
            // in one module: VorssaintBridge is ours and never conflicts on
            // merge, and it holds shims only — no logic, no state, no policy.
            sources: ["Vorssaint", "VorssaintBridge"]
        ),
        // ── END CCP PATCH ──────────────────────────────────────────────────

        // ── CCP TARGETS ────────────────────────────────────────────────────
        // Adapters over upstream's engines, plus the widget protocol, the
        // layout model, and settings. The only target that imports
        // VorssaintEngines — everything above the fork boundary stops here.
        .target(
            name: "CCPKit",
            dependencies: [
                "VorssaintEngines",
                .product(name: "PsymailKit", package: "psymail-mini"),
            ],
            path: "Sources/CCPKit"
        ),

        // The glass shell, lanes, edit mode, and the design system. Imports
        // CCPKit and never VorssaintEngines: an upstream refactor should break
        // one adapter, not the interface.
        .target(
            name: "CCPUI",
            dependencies: [
                "CCPKit",
                .product(name: "MarkdownEngine", package: "swift-markdown-engine"),
            ],
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

        .testTarget(
            name: "CCPUITests",
            dependencies: ["CCPUI"],
            path: "Tests/CCPUITests"
        ),
        // ── END CCP TARGETS ────────────────────────────────────────────────
    ]
)
